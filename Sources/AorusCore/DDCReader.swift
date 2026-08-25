//
//  DDCReader.swift
//  AorusCore
//
//  Cable-DDC/CI reads over the macOS display channel on Apple Silicon.
//
//  The USB HID controller (0x0bda:0x1100) is write-only — it cannot serve
//  status read-backs (see docs/protocol.md §5). But standard MCCS VCP codes
//  (brightness 0x10, contrast 0x12, …) are also readable over the *video cable
//  DDC* channel. On Apple Silicon that channel is reached through the private
//  IOAVService API, by locating the external display's `DCPAVServiceProxy`
//  registry service and issuing Get VCP Feature I2C transactions.
//
//  This is the pattern used by MonitorControl (Arm64DDC.swift). Everything here
//  is user-space IOKit; no driver or extra dependency is needed.
//
//  Protocol notes (verified live on a CO49DQ):
//    * A Get VCP read request is a SINGLE byte — the VCP code. The 0x01 Get
//      opcode is implied by the 1-byte form (writes use the 3-byte form).
//    * The I2C write payload is [0x80|(send.count+1), send.count] + send + ck,
//      ck seeded with (addr<<1) for the 1-byte form.
//    * A valid reply is 11 bytes: 6e 88 02 00 <vcp> 00 00 maxHi maxLo curHi curLo ck.
//      max = reply[6]*256+reply[7], current = reply[8]*256+reply[9].
//    * Replies can be stale/garbage on early rounds; retry until the reply
//      checksum (seed 0x50) validates AND reply[2]==0x02 && reply[3]==0x00.
//

import Foundation
import IOKit
import CoreGraphics

// MARK: - Private IOKit declarations

/// Opaque handle returned by `IOAVServiceCreateWithService`.

@_silgen_name("IOAVServiceCreateWithService")
private func _IOAVServiceCreateWithService(
    _ allocator: CFAllocator?, _ service: io_service_t
) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceWriteI2C")
private func _IOAVServiceWriteI2C(
    _ service: IOAVService?, _ ddcAddress: UInt32, _ dataAddress: UInt32,
    _ data: UnsafeMutableRawPointer?, _ size: UInt32
) -> kern_return_t

typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceReadI2C")
private func _IOAVServiceReadI2C(
    _ service: IOAVService?, _ ddcAddress: UInt32, _ dataAddress: UInt32,
    _ data: UnsafeMutableRawPointer?, _ size: UInt32
) -> kern_return_t

// MARK: - DDC/CI constants

/// 7-bit I2C address for DDC/CI on DisplayPort (as used by Arm64DDC).
private let ddcSevenBitAddress: UInt8 = 0x37
/// I2C data offset for the command payload.
private let ddcDataAddress: UInt8 = 0x51

/// Standard MCCS VCP codes that the CO49DQ serves via cable-DDC (verified).
public enum DisplayVCP: UInt8 {
    case luminance = 0x10
    case contrast = 0x12
    case speakerVolume = 0x62
    case sharpness = 0x87
    case inputSource = 0x60
    case colorPreset = 0x14
    case osdLanguage = 0xCC
    case powerMode = 0xD6
    case vcpVersion = 0xDF
    case firmwareLevel = 0xC9
    case displayTechType = 0xB6
    case osdState = 0xCA

    /// Human-readable label (for CLI).
    public var label: String {
        switch self {
        case .luminance:       return "luminance"
        case .contrast:        return "contrast"
        case .speakerVolume:   return "speaker-volume"
        case .sharpness:       return "sharpness"
        case .inputSource:     return "input-source"
        case .colorPreset:     return "color-preset"
        case .osdLanguage:     return "osd-language"
        case .powerMode:       return "power-mode"
        case .vcpVersion:      return "vcp-version"
        case .firmwareLevel:   return "firmware-level"
        case .displayTechType: return "display-tech-type"
        case .osdState:        return "osd-state"
        }
    }
}

/// A current+maximum value read from the display over the DDC channel.
public struct VCPReading: Sendable {
    public let current: UInt16
    public let maximum: UInt16

    /// Parses an 11-byte DDC Get VCP Feature Response into (current, max), or
    /// nil if the header or checksum is invalid. Used for tests and any caller
    /// holding a raw reply.
    public static func parse(reply: [UInt8]) -> VCPReading? {
        guard reply.count >= 10 else { return nil }
        // checksum seed 0x50; validate before trusting any field
        guard reply.validDDCChecksum else { return nil }
        // Get VCP Feature Response header: reply[2] == 0x02, reply[3] == 0x00
        guard reply[2] == 0x02, reply[3] == 0x00 else { return nil }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let currentValue = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return VCPReading(current: currentValue, maximum: maxValue)
    }
}

private extension Array where Element == UInt8 {
    /// The DDC/CI reply checksum is the XOR of all bytes with a 0x50 seed; the
    /// last byte carries the result.
    var validDDCChecksum: Bool {
        guard count >= 1 else { return false }
        var value: UInt8 = 0x50
        for index in 0..<(count - 1) { value ^= self[index] }
        return value == self[count - 1]
    }
}

// MARK: - DDCReader

/// Reads Standard MCCS VCP features over the video-cable DDC channel on Apple
/// Silicon, via the private IOAVService API. Requires an online external
/// display; returns `nil` when the display is built-in or no DDC service is
/// reachable.
///
/// Also performs **Set VCP Feature writes** (`write(_:value:)`) for standard
/// VCP codes. Standard VCP writes (brightness/contrast/volume/sharpness) MUST
/// go over this cable-DDC channel, NOT the USB HID controller — the Realtek HID
/// controller only applies vendor 0x0eXX commands; standard DDC opcodes sent
/// through HID are silently ignored on the CO49DQ (verified live).
public struct DDCReader: @unchecked Sendable {
    private let service: IOAVService?

    public init?() {
        self.service = DDCReader.findExternalService()
    }

    /// True when an external DDC service is present on this Mac (Apple Silicon).
    public var isAvailable: Bool { service != nil }

    /// Reads one VCP feature and returns (current, max), or nil on failure or
    /// unsupported.
    public func read(_ vcp: DisplayVCP) -> VCPReading? {
        readVCP(vcp.rawValue)
    }

    /// Writes `value` to a standard VCP feature via the MCCS Set VCP Feature
    /// command (opcode 0x03). Returns true on I2C success.
    @discardableResult
    public func write(_ vcp: DisplayVCP, value: UInt16) -> Bool {
        writeVCP(vcp.rawValue, value: value)
    }

    private func writeVCP(_ code: UInt8, value: UInt16) -> Bool {
        guard let service else { return false }
        let packet = DDCReader.setVCPPacket(code: code, value: value)
        let count = packet.count
        var mutablePacket = packet
        return mutablePacket.withUnsafeMutableBytes { raw -> Bool in
            _IOAVServiceWriteI2C(
                service, UInt32(ddcSevenBitAddress), UInt32(ddcDataAddress),
                raw.baseAddress, UInt32(count)
            ) == KERN_SUCCESS
        }
    }

    /// The MCCS Set VCP Feature write packet for a standard VCP code:
    /// `[0x84, 0x03, code, valueHi, valueLo, checksum]`. Exposed for tests.
    ///   * 0x84 = 0x80 | (0x03 + valueHi + valueLo + checksum = 5 msg bytes)
    ///   * 0x03 = Set VCP Feature command
    ///   * checksum seed = (0x37 << 1) ^ 0x51 = 0x6E ^ 0x51 = 0x3F
    public static func setVCPPacket(code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x84, 0x03, code,
            UInt8(value >> 8), UInt8(value & 0xff),
        ]
        packet.append(Self.writeChecksum(packet))
        return packet
    }

    private static func writeChecksum(_ data: [UInt8]) -> UInt8 {
        var value: UInt8 = (ddcSevenBitAddress << 1) ^ ddcDataAddress  // 0x3F
        for byte in data { value ^= byte }
        return value
    }

    /// Raw read-by-code variant.
    public func readVCP(_ code: UInt8) -> VCPReading? {
        guard let service else { return nil }
        let count = 11
        var reply = [UInt8](repeating: 0, count: count)

        for _ in 0..<10 {
            writeGetRequest(service: service, vcp: code)
            usleep(60_000)
            readReply(service: service, into: &reply)
            usleep(20_000)

            if let reading = VCPReading.parse(reply: reply) { return reading }
        }
        return nil
    }

    // MARK: Low-level helpers

    private func writeGetRequest(service: IOAVService, vcp: UInt8) {
        // 1-byte send => Get VCP opcode 0x01 is implied by the short form.
        let send: [UInt8] = [vcp]
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let seed = ddcSevenBitAddress << 1
        packet[packet.count - 1] = checksum(seed: seed, data: packet, start: 0, end: packet.count - 2)
        let count = packet.count
        packet.withUnsafeMutableBytes { raw in
            _ = _IOAVServiceWriteI2C(
                service, UInt32(ddcSevenBitAddress), UInt32(ddcDataAddress),
                raw.baseAddress, UInt32(count)
            )
        }
    }

    private func readReply(service: IOAVService, into reply: inout [UInt8]) {
        let count = reply.count
        reply.withUnsafeMutableBytes { raw in
            _ = _IOAVServiceReadI2C(
                service, UInt32(ddcSevenBitAddress), 0, raw.baseAddress, UInt32(count)
            )
        }
    }

    private func checksum(seed: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
        var value = seed
        var index = start
        while index <= end {
            value ^= data[index]
            index += 1
        }
        return value
    }

    // MARK: Service discovery

    /// Iterates the I/O Registry for the external display's `DCPAVServiceProxy`
    /// and creates an IOAVService handle for it.
    private static func findExternalService() -> IOAVService? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        var iterator = io_iterator_t()
        defer {
            IOObjectRelease(iterator)
            IOObjectRelease(root)
        }
        guard IORegistryEntryCreateIterator(
            root, "IOService",
            IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else {
            return nil
        }

        var found: IOAVService?
        while found == nil {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            let namePtr = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
            if IORegistryEntryGetName(entry, namePtr) == KERN_SUCCESS,
               String(cString: namePtr).contains("DCPAVServiceProxy") {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, IOOptionBits()) == KERN_SUCCESS,
                   let props {
                    let dict = props.takeRetainedValue() as NSDictionary
                    if (dict["Location"] as? String) == "External" {
                        found = _IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
                    }
                }
            }
            namePtr.deallocate()
            IOObjectRelease(entry)
        }
        return found
    }
}
