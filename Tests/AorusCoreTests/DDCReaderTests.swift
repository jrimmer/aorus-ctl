//
//  DDCReaderTests.swift
//  AorusCoreTests
//
//  Verifies the deterministic parts of the cable-DDC read path: reply checksum
//  validation (seed 0x50) and Get VCP Feature Response parsing. These match the
//  live replies captured from a CO49DQ, so they double as a golden reference.
//

import XCTest
@testable import AorusCore

final class DDCReaderTests: XCTestCase {

    /// A real, checksum-valid luminance reply observed on the CO49DQ:
    /// brightness current=75, max=100.
    func testParseBrightnessReply() {
        // 6e 88 02 00 10 00 00 64 00 4b 8b
        let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4b, 0x8b]
        guard let reading = VCPReading.parse(reply: reply) else {
            XCTFail("expected a valid parse")
            return
        }
        XCTAssertEqual(reading.current, 75)
        XCTAssertEqual(reading.maximum, 100)
    }

    /// Contrast reply observed on the CO49DQ: current=50, max=100.
    func testParseContrastReply() {
        // 6e 88 02 00 12 00 00 64 00 32 f0
        let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x32, 0xf0]
        guard let reading = VCPReading.parse(reply: reply) else {
            XCTFail("expected a valid parse")
            return
        }
        XCTAssertEqual(reading.current, 50)
        XCTAssertEqual(reading.maximum, 100)
    }

    /// All-zero (stale) replies must be rejected, not parsed as 0/0.
    func testRejectsStaleReply() {
        let reply = [UInt8](repeating: 0, count: 11)
        XCTAssertNil(VCPReading.parse(reply: reply))
    }

    /// Wrong response type (0xbe instead of 0x02) must be rejected.
    func testRejectsNonVCPResponseType() {
        // 6e 80 be 00 ... (the "echo" form the device can return)
        var reply = [UInt8](repeating: 0, count: 11)
        reply[0] = 0x6e
        reply[1] = 0x80
        reply[2] = 0xbe
        // Build a matching checksum so only the header type is at fault.
        reply[10] = reply.dropLast().reduce(0x50) { $0 ^ $1 }
        XCTAssertNil(VCPReading.parse(reply: reply))
    }

    /// Error opcode byte must be rejected even with valid checksum.
    func testRejectsErrorStatus() {
        // Build a valid Get VCP structure but with reply[3] set to a non-zero
        // error code, and a correct checksum.
        var reply: [UInt8] = [0x6e, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4b, 0x00]
        reply[10] = reply.dropLast().reduce(0x50) { $0 ^ $1 }
        XCTAssertNil(VCPReading.parse(reply: reply))
    }
}
