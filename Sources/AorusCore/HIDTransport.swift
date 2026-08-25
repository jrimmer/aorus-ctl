//
//  HIDTransport.swift
//  AorusCore
//
//  Device discovery and report I/O over IOKit's HID manager. No third-party
//  dependencies. macOS ships everything needed to open a USB HID device,
//  claim it, send a feature/output report, and read its responses.
//

import Foundation
import IOKit
import IOKit.hid

public enum TransportError: Error, CustomStringConvertible, LocalizedError {
    case notFound(vid: Int, pid: Int, more: String)
    case openFailed(Int32)
    case reportWriteFailed(Int32)
    case reportReadFailed(Int32)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .notFound(let vid, let pid, let more):
            return "No matching HID device found (VID 0x\(String(vid, radix: 16)):0x\(String(pid, radix: 16))). \(more)"
        case .openFailed(let status):
            return "Failed to open HID device (IOKit status \(status)). Try: ensure the monitor's USB upstream cable is connected. If the device is in use, quit other monitor control apps."
        case .reportWriteFailed(let status):
            return "Failed to write HID report (IOKit status \(status))."
        case .reportReadFailed(let status):
            return "Failed to read HID report (IOKit status \(status))."
        case .invalidInput(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// A discovered monitor control HID device.
public struct MonitorDevice: Identifiable, Equatable, Sendable {
    public let id: UInt64          // session/unique id
    public let vid: Int
    public let pid: Int
    public let productName: String
    public let manufacturer: String

    public var description: String {
        let vidHex = String(vid, radix: 16)
        let pidHex = String(pid, radix: 16)
        let who = manufacturer.isEmpty ? "unknown" : manufacturer
        return String(format: "0x%@:0x%@  %@  [%@]", vidHex.padding(toLength: 4, withPad: "0", startingAt: 0), pidHex.padding(toLength: 4, withPad: "0", startingAt: 0), productName, who)
    }
}

/// Default Realtek HID controller used by Gigabyte monitors (OSD Sidekick).
public let defaultVendorID = 0x0bda
public let defaultProductID = 0x1100

/// Enumerates HID devices, returning those matching the monitor control VID/PID.
/// Defaults to the Realtek 0x0bda:0x1100 controller; pass overrides to match
/// other controllers or to enumerate everything (vid = -1).
public func findMonitorDevices(vid: Int = defaultVendorID, pid: Int = defaultProductID) -> [MonitorDevice] {
    var result: [MonitorDevice] = []

    // Legacy but reliable: iterate IORegistry for IOUSBHostHIDDevice entries
    // with a matching idVendor/idProduct.
    let matching = IOServiceMatching(kIOHIDDeviceKey)
    let iterator: io_iterator_t = {
        var it: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it)
        return it
    }()

    defer { IOObjectRelease(iterator) }

    while true {
        let reg = IOIteratorNext(iterator)
        if reg == 0 { break }
        defer { IOObjectRelease(reg) }

        guard let props = ioValueProperties(reg) else { continue }
        guard let matchedVidRaw = props["idVendor"] as? Int,
              let matchedPidRaw = props["idProduct"] as? Int else { continue }

        let matchVid = (vid == -1) || (matchedVidRaw == vid)
        let matchPid = (pid == -1) || (matchedPidRaw == pid)
        guard matchVid && matchPid else { continue }

        let uniqueID = (props["UniqueID"] as? Int).flatMap { UInt64($0) }
            ?? UInt64(truncatingIfNeeded: reg)

        result.append(MonitorDevice(
            id: uniqueID,
            vid: matchedVidRaw,
            pid: matchedPidRaw,
            productName: props["Product"] as? String ?? "",
            manufacturer: props["Manufacturer"] as? String ?? ""
        ))
    }

    return result
}

private func ioValueProperties(_ service: io_service_t) -> [String: Any]? {
    var props: Unmanaged<CFMutableDictionary>?
    let status = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
    guard status == KERN_SUCCESS, let retained = props?.takeRetainedValue() else { return nil }
    return retained as NSDictionary as? [String: Any]
}

/// A live connection to a monitor control HID device.
public final class MonitorConnection: @unchecked Sendable {
    private var deviceRef: IOHIDDevice?

    /// Opens the given device and requests exclusive read access.
    public init?(device: MonitorDevice) {
        guard let service = findDeviceService(vid: device.vid, pid: device.pid, uniqueID: device.id) else {
            return nil
        }
        let ref = IOHIDDeviceCreate(kCFAllocatorDefault, service)
        IOObjectRelease(service)
        guard let ref else { return nil }
        let openResult = IOHIDDeviceOpen(ref, 0)
        guard openResult == kIOReturnSuccess else {
            return nil
        }
        self.deviceRef = ref
    }

    deinit {
        if let ref = deviceRef {
            IOHIDDeviceClose(ref, 0)
        }
    }

    /// Writes a 193-byte report (report id 0 + 192-byte payload) as an output
    /// report. This is the exact operation OSD Sidekick performs.
    @discardableResult
    public func write(report: [UInt8]) throws -> Int {
        guard let ref = deviceRef else { throw TransportError.reportWriteFailed(-1) }
        guard report.count <= 193 else {
            throw TransportError.invalidInput("Report must be at most 193 bytes (got \(report.count))")
        }
        // Buffer must be report-id (1) + payload for IOHIDDeviceSetReport.
        var buffer = report
        if buffer.count < 1 { buffer.insert(0, at: 0) }
        let reportID = CFIndex(buffer[0]) // report id
        let bufferCount = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            IOHIDDeviceSetReport(
                ref,
                kIOHIDReportTypeOutput,
                reportID,
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                bufferCount
            )
        }
        guard status == kIOReturnSuccess else {
            throw TransportError.reportWriteFailed(status)
        }
        return buffer.count
    }

    /// Reads the feature/input report containing current status.
    public func read() throws -> [UInt8] {
        guard let ref = deviceRef else { throw TransportError.reportReadFailed(-1) }
        var buffer = [UInt8](repeating: 0, count: 193)
        var length = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            IOHIDDeviceGetReport(
                ref,
                kIOHIDReportTypeInput,
                0,
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                &length
            )
        }
        guard status == kIOReturnSuccess else {
            throw TransportError.reportReadFailed(status)
        }
        return Array(buffer.prefix(length))
    }
}

private func findDeviceService(vid: Int, pid: Int, uniqueID: UInt64?) -> io_service_t? {
    let matching = IOServiceMatching(kIOHIDDeviceKey)
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard status == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }

    while true {
        let reg = IOIteratorNext(iterator)
        if reg == 0 { break }

        guard let props = ioValueProperties(reg),
              let matchedVid = props["idVendor"] as? Int,
              let matchedPid = props["idProduct"] as? Int else {
            IOObjectRelease(reg)
            continue
        }
        if matchedVid == vid && matchedPid == pid {
            if let uniqueID {
                let uid = (props["UniqueID"] as? Int).flatMap { UInt64($0) }
                if uid != uniqueID {
                    IOObjectRelease(reg)
                    continue
                }
            }
            return reg
        }
        IOObjectRelease(reg)
    }
    return nil
}
