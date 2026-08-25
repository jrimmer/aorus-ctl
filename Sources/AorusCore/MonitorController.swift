//
//  MonitorController.swift
//  AorusCore
//
//  High-level control surface: set a property, dump raw status, and a small
//  "known chipsets" query. Kept dependency-free for reuse by both the CLI and
//  a future SwiftUI menu-bar app.
//

import Foundation

public struct MonitorController: Sendable {
    public let connection: MonitorConnection

    public init(connection: MonitorConnection) {
        self.connection = connection
    }

    /// Opens the first matching monitor control device. Throws if none found.
    public static func openFirst(
        vid: Int = defaultVendorID,
        pid: Int = defaultProductID
    ) throws -> MonitorController {
        let devices = findMonitorDevices(vid: vid, pid: pid)
        guard let first = devices.first else {
            throw TransportError.notFound(
                vid: vid, pid: pid,
                more: "Connect the monitor's USB upstream (USB-B or USB-C). See README for troubleshooting."
            )
        }
        guard let conn = MonitorConnection(device: first) else {
            throw TransportError.openFailed(-1)
        }
        return MonitorController(connection: conn)
    }

    /// Sets a monitor property to the given value (within its range).
    public func set(_ control: MonitorControl, value: UInt16) throws {
        let report = try ReportBuilder.buildReport(control: control, value: value)
        try connection.write(report: report)
    }

    /// Reads the current 193-byte status report as hex bytes.
    public func dumpStatus() throws -> [UInt8] {
        try connection.read()
    }
}

/// Human-readable hex dump formatting shared by CLI and future app.
public func hexDump(_ bytes: [UInt8], addressWidth: Int = 8) -> String {
    var lines: [String] = []
    var address = 0
    while address < bytes.count {
        let chunk = Array(bytes[address..<min(address + 16, bytes.count)])
        let hexPart = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        let asciiPart = chunk.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        lines.append(String(format: "%0\(addressWidth)x  %@  %@", address, hexPart.padding(toLength: 47, withPad: " ", startingAt: 0), asciiPart))
        address += 16
    }
    return lines.joined(separator: "\n")
}
