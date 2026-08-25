//
//  FrameBuilderTests.swift
//  AorusCoreTests
//
//  Verifies report byte-level correctness against the proven kelvie/gbmonctl
//  driver (the primary tested reference on the M32U/M32Q family). gbmonctl's
//  exact frame construction:
//    * buf[0] report id 0, buf[1..2] 0x40 0xc6, buf[7..11] 20 00 6e 00 80
//    * at payload 0x40: 0x51, 0x81 + len(msg), 0x03 (write opcode)
//    * msg = command bytes (1 for standard DDC 0x10/0x12/0x87, 2 for vendor
//      0xe0XX) followed by the value as a 2-byte big-endian uint16
//    * NO checksum byte — gbmonctl leaves the trailing bytes zero
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

    /// Standard DDC control: single command byte, 2-byte big-endian value,
    /// length 0x81 + 3 = 0x84, no checksum.
    func testBrightnessFrameLayout() throws {
        let report = try build(.brightness, 75) // 0x004b
        XCTAssertEqual(report[1 + 0x43], 0x10) // command
        XCTAssertEqual(report[1 + 0x44], 0x00) // value high
        XCTAssertEqual(report[1 + 0x45], 0x4b) // value low
        XCTAssertEqual(report[1 + 0x41], 0x84) // len = 0x81 + 3 msg bytes
        // gbmonctl appends no checksum: the byte after is zero.
        XCTAssertEqual(report[1 + 0x46], 0x00)
    }

    /// Contrast value is a 2-byte big-endian field.
    func testContrastValuePlacement() throws {
        let report = try build(.contrast, 60) // 0x003c
        XCTAssertEqual(report[1 + 0x43], 0x12)
        XCTAssertEqual(report[1 + 0x44], 0x00)
        XCTAssertEqual(report[1 + 0x45], 0x3c)
    }

    /// Vendor controls use a 2-byte 0xe0XX command word.
    func testVendorControlLayout() throws {
        let report = try build(.blackEqualizer, 10) // 0xe000, value 0x000a
        XCTAssertEqual(report[1 + 0x41], 0x85) // len = 0x81 + 2 cmd + 2 val
        XCTAssertEqual(report[1 + 0x43], 0xe0) // vendor prefix
        XCTAssertEqual(report[1 + 0x44], 0x00) // subcode high
        XCTAssertEqual(report[1 + 0x45], 0x00) // value high
        XCTAssertEqual(report[1 + 0x46], 0x0a) // value low
    }

    /// KVM switch uses vendor command 0xe069 with a 2-byte value.
    func testKvmSwitchCommand() throws {
        let report = try build(.kvmSwitch, 1) // 0xe069, value 0x0001
        XCTAssertEqual(report[1 + 0x43], 0xe0)
        XCTAssertEqual(report[1 + 0x44], 0x69)
        XCTAssertEqual(report[1 + 0x45], 0x00)
        XCTAssertEqual(report[1 + 0x46], 0x01)
    }

    /// PBP mode uses vendor command 0xe00e with a 2-byte value.
    func testPbpPipModeCommand() throws {
        let report = try build(.pbpPipMode, 2) // 0xe00e, value 0x0002
        XCTAssertEqual(report[1 + 0x43], 0xe0)
        XCTAssertEqual(report[1 + 0x44], 0x0e)
        XCTAssertEqual(report[1 + 0x45], 0x00)
        XCTAssertEqual(report[1 + 0x46], 0x02)
    }

    /// Picture mode uses vendor command 0xe02c.
    func testPictureModeCommand() throws {
        let report = try build(.pictureMode, 3) // 0xe02c, value 0x0003
        XCTAssertEqual(report[1 + 0x43], 0xe0)
        XCTAssertEqual(report[1 + 0x44], 0x2c)
        XCTAssertEqual(report[1 + 0x45], 0x00)
        XCTAssertEqual(report[1 + 0x46], 0x03)
    }

    /// After the message the report is all zeros (no checksum, matching
    /// gbmonctl): verify a vendor control leaves zeros immediately after the
    /// 2-byte value.
    func testNoChecksumByte() throws {
        let report = try build(.source, 3) // 0xe02d
        // 2 cmd + 2 val = 4 msg bytes; first msg byte at 0x43.
        let msgStart = 1 + 0x43
        let msgEnd = msgStart + 4
        // The byte right after the message (where a checksum would live) is 0.
        XCTAssertEqual(report[msgEnd], 0x00)
    }

    func testOutOfRangeThrows() {
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .brightness, value: 101))
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .sharpness, value: 11))
        XCTAssertThrowsError(try ReportBuilder.buildReport(control: .kvmSwitch, value: 2))
        // Boundary values should succeed.
        XCTAssertNoThrow(try ReportBuilder.buildReport(control: .brightness, value: 100))
        XCTAssertNoThrow(try ReportBuilder.buildReport(control: .kvmSwitch, value: 1))
    }
}
