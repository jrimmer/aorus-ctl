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
    /// Optional registry UniqueID. Present on real USB devices; nil when the
    /// registry exposes no UniqueID (in which case the service is matched by
    /// VID/PID alone).
    public let id: UInt64?
    public let vid: Int
    public let pid: Int
    public let productName: String
    public let manufacturer: String

    public var description: String {
        let vidHex = String(format: "%04x", vid)
        let pidHex = String(format: "%04x", pid)
        let who = manufacturer.isEmpty ? "unknown" : manufacturer
        return "0x\(vidHex):0x\(pidHex)  \(productName)  [\(who)]"
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

    // Enumerate HID devices via IOKit and match the Realtek controller.
    // NOTE: on the HID device plane the properties are brought in under the
    // capitalized keys `VendorID` / `ProductID` (NSNumber), NOT the lowercase
    // `idVendor` / `idProduct` which live on the USB host-device plane.
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
        guard let matchedVidRaw = numericProperty(props, "VendorID"),
              let matchedPidRaw = numericProperty(props, "ProductID") else { continue }

        let matchVid = (vid == -1) || (matchedVidRaw == vid)
        let matchPid = (pid == -1) || (matchedPidRaw == pid)
        guard matchVid && matchPid else { continue }

        let uniqueID = (props["UniqueID"] as? NSNumber)?.uint64Value
            ?? (props["UniqueID"] as? UInt64)

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

/// Extracts a registry integer property, which IOKit bridges unpredictably as
/// NSNumber, Int, UInt32, or String — handle all of them.
private func numericProperty(_ props: [String: Any], _ key: String) -> Int? {
    guard let value = props[key] else { return nil }
    return numeric(from: value)
}

private func numeric(from value: Any) -> Int? {
    switch value {
    case let number as NSNumber:
        return number.intValue
    case let integer as Int:
        return integer
    case let integer as Int32:
        return Int(integer)
    case let integer as Int64:
        return Int(truncatingIfNeeded: integer)
    case let integer as UInt32:
        return Int(integer)
    case let integer as UInt64:
        return Int(truncatingIfNeeded: integer)
    case let string as String:
        return Int(string, radix: 16) ?? Int(string)
    default:
        return nil
    }
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

    /// Writes the 192-byte payload as an output report. The report descriptor
    /// for this device has NO report-ID item — it expects a bare 192-byte
    /// output report (MaxOutputReportSize = 192). Passing a 193-byte buffer
    /// (the conventional leading report-ID byte + 192 payload) makes the host
    /// form an oversized SET_REPORT that the device STALLs
    /// (kUSBHostReturnPipeStalled, 0xE0005000). So the leading report-ID byte
    /// is sliced off and only the 192-byte payload is transmitted with
    /// reportID 0.
    @discardableResult
    public func write(report: [UInt8]) throws -> Int {
        guard let ref = deviceRef else { throw TransportError.reportWriteFailed(-1) }
        // `report` is the 193-byte frame: report[0] = report id 0, report[1...] =
        // the 192-byte vendor payload. The device accepts exactly the 192-byte
        // payload with reportID 0. Slice off the leading report-id byte.
        guard report.count >= 2 else {
            throw TransportError.invalidInput("Report must include the 192-byte payload (got \(report.count) bytes)")
        }
        let payload = Array(report[1...]) // exactly 192 bytes
        let reportID = CFIndex(0)
        let bufferCount = payload.count
        let status = payload.withUnsafeBytes { raw -> IOReturn in
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
        return payload.count
    }

    /// Reads the current status as a 192-byte input report (report type
    /// input). The device reports MaxInputReportSize = 192 with no report-ID
    /// item, so a 192-byte buffer is used, matching the output-report fix.
    public func read() throws -> [UInt8] {
        guard let ref = deviceRef else { throw TransportError.reportReadFailed(-1) }
        var buffer = [UInt8](repeating: 0, count: 192)
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
              let matchedVid = numericProperty(props, "VendorID"),
              let matchedPid = numericProperty(props, "ProductID") else {
            IOObjectRelease(reg)
            continue
        }
        if matchedVid == vid && matchedPid == pid {
            if let uniqueID {
                let uid = (props["UniqueID"] as? NSNumber)?.uint64Value
                    ?? (props["UniqueID"] as? UInt64)
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
