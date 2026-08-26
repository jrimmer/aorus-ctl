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
    /// Cable-DDC handle for standard MCCS VCP controls (brightness/contrast/
    /// volume/sharpness). These MUST be written over the video-cable DDC
    /// channel; the USB HID controller ignores standard DDC opcodes.
    let ddc: DDCReader?

    public init(connection: MonitorConnection, ddc: DDCReader? = nil) {
        self.connection = connection
        self.ddc = ddc
    }

    /// Opens the first matching monitor control device. Also opens the
    /// cable-DDC channel so standard VCP controls can be read/written.
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
        return MonitorController(connection: conn, ddc: DDCReader())
    }

    /// Whether a monitor control device is currently present on the USB/HID
    /// bus. Cheap enumeration that doesn't hold a handle; used by the app to
    /// detect a dropped upstream connection (the HID controller can vanish
    /// while the video path stays up, e.g. after an input/PBP-PIP re-route).
    public static func isDevicePresent(
        vid: Int = defaultVendorID, pid: Int = defaultProductID
    ) -> Bool {
        !findMonitorDevices(vid: vid, pid: pid).isEmpty
    }

    /// Sets a monitor property to the given value (within its range).
    ///
    /// Standard VCP controls (brightness/contrast/volume/sharpness) are
    /// written over the **cable-DDC** channel; vendor controls (KVM, PBP/PIP,
    /// picture modes, colour, …) are written over the **USB HID** controller.
    public func set(_ control: MonitorControl, value: UInt16) throws {
        if let vcp = control.standardVCP, let ddc {
            guard ddc.write(vcp, value: value) else {
                throw TransportError.reportWriteFailed(-1)
            }
            return
        }
        let report = try ReportBuilder.buildReport(control: control, value: value)
        try connection.write(report: report)
    }

    /// Reads the current value of a standard VCP control over cable-DDC, or nil
    /// if the control is not a standard VCP or the read fails.
    public func read(_ control: MonitorControl) -> VCPReading? {
        guard let vcp = control.standardVCP, let ddc else { return nil }
        return ddc.read(vcp)
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
