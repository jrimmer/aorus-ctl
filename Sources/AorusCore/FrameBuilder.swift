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

        // Determine command bytes: single-byte-ish controls are a single byte,
        // vendor controls (0x0e XX) are two bytes.
        let command = control.commandWord
        let commandBytes: [UInt8]
        if command > 0xff {
            commandBytes = [UInt8(command >> 8), UInt8(command & 0xff)]
        } else {
            commandBytes = [UInt8(command & 0xff)]
        }

        // Message length byte = 0x81 + commandBytes.count + value bytes(1).
        // (gbmonctl uses 0x81 + len for writes; the 0x83/0x84 sequence seen in
        //  pcaps is a separate commit handshake the proven driver omits.)
        report[base + 1] = 0x81 + UInt8(commandBytes.count + 1)
        report[base + 2] = 0x03 // write opcode

        // Command bytes.
        for (idx, byte) in commandBytes.enumerated() {
            report[base + 3 + idx] = byte
        }

        // Value byte.
        report[base + 3 + commandBytes.count] = UInt8(value & 0xff)

        // Checksum byte follows the value.
        let checksumIndex = base + 3 + commandBytes.count + 1
        report[checksumIndex] = checksum(for: report)
        return report
    }

    /// Computes the protocol checksum.
    ///
    /// Mirrors gbmonctl's exact logic:
    ///   low  nibble = XOR of every byte's low nibble, starting at 0x6
    ///   high nibble = (last byte XOR 0xc0) high nibble
    private static func checksum(for report: [UInt8]) -> UInt8 {
        // The message part here is the region [0x43...checksum of the payload],
        // i.e. everything from the first command byte up to (not including) the
        // checksum byte. gbmonctl computes it over the whole `msg` (command +
        // value) which it placed at payload[0x43..]. We replicate by sweeping
        // the command+value region of the payload.
        // Payload offset of first command byte is 0x43.
        let msgStart = 1 + 0x43
        // length of msg = checksumIndex - msgStart (we locate value by scanning).
        guard report.count >= 1 + 0x43 else { return 0 }

        // Find the checksum byte boundary: it sits immediately after the
        // value byte. The message length byte at payload[0x41] encodes
        // 0x81 + (command bytes + value byte). Decode accordingly.
        let lenByte = Int(report[1 + 0x41])
        let msgLen = lenByte - 0x81 // command bytes + value byte
        let end = msgStart + msgLen // exclusive; the checksum is here

        var sum: UInt8 = 0x6
        if end > 1 + 0x43 {
            for idx in (1 + 0x43)..<min(end, report.count) {
                sum ^= report[idx]
            }
        }
        sum &= 0x0f

        let lastMsgByte = report[msgStart + msgLen - 1]
        let highNibble = (lastMsgByte ^ 0xc0) & 0xf0
        return sum + highNibble
    }
}
