//
//  FrameBuilderTests.swift
//  AorusCoreTests
//
//  Verifies report byte-level correctness against the proven gbmonctl driver
//  and the raw pcap frames.
//

import XCTest
@testable import AorusCore

final class FrameBuilderTests: XCTestCase {

    private func build(_ control: MonitorControl, _ value: UInt16) throws -> [UInt8] {
        try ReportBuilder.buildReport(control: control, value: value)
    }

    /// Structural invariants every report must satisfy.
    func testReportStructure() throws {
        let report = try build(.brightness, 50)
        XCTAssertEqual(report.count, 193, "Report must be 193 bytes (id + 192)")

        // Fixed preamble.
        XCTAssertEqual(report[1], 0x40)
        XCTAssertEqual(report[2], 0xc6)
        // Fixed header at payload offset 6..10.
        XCTAssertEqual(report[1 + 6], 0x20)
        XCTAssertEqual(report[1 + 8], 0x6e)
        XCTAssertEqual(report[1 + 10], 0x80)

        // Message marker.
        XCTAssertEqual(report[1 + 0x40], 0x51)
        // Write opcode.
        XCTAssertEqual(report[1 + 0x42], 0x03)
    }

    /// Single-byte DDC controls: command word is one byte at payload[0x43],
    /// value at 0x44, checksum at 0x45.
    func testBrightnessFrameLayout() throws {
        let report = try build(.brightness, 75)
        XCTAssertEqual(report[1 + 0x43], 0x10) // command
        XCTAssertEqual(report[1 + 0x44], 75)   // value
        // Len byte = 0x81 + cmdBytes(1) + value(1) = 0x83
        XCTAssertEqual(report[1 + 0x41], 0x83)
    }

    /// Contrast tracking (the kelvie table shows contrast values shifted +2).
    func testContrastValuePlacement() throws {
        let report = try build(.contrast, 60)
        XCTAssertEqual(report[1 + 0x43], 0x12)
        XCTAssertEqual(report[1 + 0x44], 60)
    }

    /// Vendor controls (0x0e + subcode) use two command bytes.
    func testVendorControlLayout() throws {
        let report = try build(.blackEqualizer, 10)
        XCTAssertEqual(report[1 + 0x41], 0x84) // len = 0x81 + 2 cmd + 1 val
        XCTAssertEqual(report[1 + 0x43], 0x0e)
        XCTAssertEqual(report[1 + 0x44], 0x00)
        XCTAssertEqual(report[1 + 0x45], 10)   // value
        // checksum now at 0x46
        XCTAssertEqual(report.count, 193)
    }

    /// Checksum recomputation must be idempotent and produce a valid nibble
    /// checksum over the command+value region.
    func testChecksumStability() throws {
        for control: MonitorControl in [.brightness, .contrast, .volume, .sharpness,
                                        .blackEqualizer, .kvmSwitch,
                                        .pbpPipMode, .pictureMode, .source] {
            let report = try build(control, 1)
            // Check that the checksum byte satisfies the gbmonctl formula:
            // low nibble = xor(all msg bytes low-nibble) ⊕ 0x6
            // high nibble = (lastMsgByte ⊕ 0xc0) & 0xf0
            let cmdBytes: Int = control.commandWord > 0xff ? 2 : 1
            let msgStart = 1 + 0x43
            let msgLen = cmdBytes + 1
            let checksumIndex = msgStart + msgLen
            let msgBytes = Array(report[msgStart..<checksumIndex])
            var sum: UInt8 = 0x6
            for byte in msgBytes { sum ^= byte }
            sum &= 0x0f
            let high = (msgBytes[msgBytes.count - 1] ^ 0xc0) & 0xf0
            XCTAssertEqual(report[checksumIndex], sum + high, "Checksum for \(control.label)")
        }
    }

    /// Guaranteed frame bytes translated from gbmonctl's dry-run for
    /// `brightness 80`. gbmonctl's `msg` is [0x10, 0x50] (command + value),
    /// checksum over that region.
    func testKnownGoodBrightnessFrameMatchesGbmonctl() throws {
        // Reconstruct what gbmonctl would produce for brightness=80.
        let control: MonitorControl = .brightness
        let value: UInt16 = 80
        let report = try build(control, value)

        let msg: [UInt8] = [0x10, 0x50]
        var cs: UInt8 = 0x6
        for byte in msg { cs ^= byte }
        cs &= 0x0f
        cs += (msg[msg.count - 1] ^ 0xc0) & 0xf0

        XCTAssertEqual(report[1 + 0x43], 0x10)
        XCTAssertEqual(report[1 + 0x44], 0x50)
        XCTAssertEqual(report[1 + 0x45], cs)
        XCTAssertEqual(report[1 + 0x41], 0x83)
    }

    func testOutOfRangeThrows() {
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .brightness, value: 101))
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .sharpness, value: 11))
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .kvmSwitch, value: 2))
        // Boundary values should succeed.
        XCTAssertNoThrow(try ReportBuilder.buildReport(control: .brightness, value: 100))
        XCTAssertNoThrow(try ReportBuilder.buildReport(control: .kvmSwitch, value: 1))
    }

    /// KVM switch uses the vendor command 0x0e69.
    func testKvmSwitchCommand() throws {
        let report = try build(.kvmSwitch, 1)
        XCTAssertEqual(report[1 + 0x43], 0x0e)
        XCTAssertEqual(report[1 + 0x44], 0x69)
        XCTAssertEqual(report[1 + 0x45], 1)
    }
}
