//
//  FrameBuilder.swift
//  AorusCore
//
//  Builds the 192-byte vendor report (plus a leading report-id byte) that
//  Gigabyte's HID control interface consumes.
//
//  Layout (all offsets are within the 192-byte report, i.e. `report[1...]`):
//    [0]   0x40 0xc6                       fixed preamble
//    [6]   0x20 0x00 0x6e 0x00 0x80        fixed header
//    [0x40] 0x51 0x81+len 0x03             message header
//    [0x43] command bytes (0x10/0x12/0x87 for single-byte DDC, or 0x0e 0xYY
//           for vendor controls), then the value, then a checksum byte.
//
//  The layout exactly matches the proven driver in kelvie/gbmonctl and the
//  pcap disassembly in the kelvie OSD-sidekick reversing gist. The checksum
//  is a nibble-wise XOR: high nibble = xor of all bytes' low nibbles ⊕ 0x6;
//  low nibble = (last byte ⊕ 0xc0) high nibble. See checksumReport().
//

import Foundation

public enum FrameError: Error, CustomStringConvertible {
    case valueOutOfRange(control: MonitorControl, requested: UInt16, range: ClosedRange<UInt16>)

    public var description: String {
        switch self {
        case .valueOutOfRange(let control, let value, let range):
            return "value \(value) for \(control.label) is outside valid range \(range.lowerBound)-\(range.upperBound)"
        }
    }
}

public struct ReportBuilder {
    /// Report length including the leading report-id byte.
    public static let reportLength = 193

    /// Builds the full 193-byte report for writing `value` to `control`.
    ///
    /// Exactly mirrors kelvie/gbmonctl's proven frame construction:
    ///   * `buf[0]` report id 0, `buf[1..2]` 0x40 0xc6, `buf[7..11]` 20 00 6e 00 80
    ///   * at payload 0x40: `0x51`, `0x81 + len(msg)`, `0x03` (write opcode)
    ///   * `msg` = command bytes (1 for standard DDC 0x10/0x12/0x87, 2 for
    ///     vendor 0xe0XX) followed by the value as a **2-byte big-endian**
    ///     uint16 — gbmonctl always emits the value as two bytes.
    ///   * gbmonctl does **not** append a checksum byte; the trailing bytes of
    ///     the 192-byte report are left zero. We replicate that behaviour.
    public static func buildReport(control: MonitorControl, value: UInt16) throws -> [UInt8] {
        guard control.range.contains(value) else {
            throw FrameError.valueOutOfRange(control: control, requested: value, range: control.range)
        }

        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = 0 // ReportID 0

        // Offset 1.. = payload. Payload index 0 = 0x40, 1 = 0xc6.
        report[1] = 0x40
        report[2] = 0xc6
        // Payload index 6 = 0x20, 7 = 0x00, 8 = 0x6e, 9 = 0x00, 10 = 0x80
        report[1 + 6] = 0x20
        report[1 + 7] = 0x00
        report[1 + 8] = 0x6e
        report[1 + 9] = 0x00
        report[1 + 10] = 0x80

        // Command message starting at payload index 0x40.
        let base = 1 + 0x40
        report[base] = 0x51

        // Command bytes: single byte for standard DDC (0x10/0x12/0x87), two
        // bytes for vendor 0xe0XX.
        let command = control.commandWord
        let commandBytes: [UInt8]
        if command > 0xff {
            commandBytes = [UInt8(command >> 8), UInt8(command & 0xff)]
        } else {
            commandBytes = [UInt8(command & 0xff)]
        }

        // Message = command bytes + 2-byte big-endian value (gbmonctl always
        // emits value as a uint16).
        let valueBytes: [UInt8] = [UInt8(value >> 8), UInt8(value & 0xff)]
        let msgLen = commandBytes.count + valueBytes.count

        // Message length byte = 0x81 + len(msg).
        report[base + 1] = 0x81 + UInt8(msgLen)
        report[base + 2] = 0x03 // write opcode

        for (idx, byte) in commandBytes.enumerated() {
            report[base + 3 + idx] = byte
        }
        for (idx, byte) in valueBytes.enumerated() {
            report[base + 3 + commandBytes.count + idx] = byte
        }

        // No checksum byte — gbmonctl leaves the remaining bytes zero.
        return report
    }
}
