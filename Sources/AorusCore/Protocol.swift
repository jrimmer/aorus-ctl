//
//  Protocol.swift
//  AorusCore
//
//  Reverse-engineered USB HID control protocol for Gigabyte/AORUS monitors
//  that are driven by the Windows-only "OSD Sidekick" application.
//
//  This is the community-decoded protocol used across the M27Q / M32U /
//  M32Q / M32QC / M28UC family. Gigabyte monitors in this family expose a
//  Realtek HID device (VID 0x0bda / PID 0x1100) whose vendor control
//  interface effectively encapsulates DDC/CI. The command opcodes below are
//  the same ones used over the HDMI/DP/Type-C DDC/CI path.
//
//  Sources / prior art:
//    - https://github.com/kelvie/gbmonctl            (working Go driver)
//    - https://github.com/ayufan-research/gigabyte-m32u-ddcctl (full table)
//    - https://gist.github.com/kelvie/fa562c4643c4abc8d91bb192b325995b
//    - https://github.com/wadimw/... (macOS PyUSB brightness sync)
//

public enum MonitorControl: Equatable, Hashable, Sendable {
    /// Standard DDC/CI controls (single-byte data, 0-100 unless noted).
    case brightness      // 0x10
    case contrast        // 0x12
    case volume          // 0x62
    case sharpness       // 0x87 (0-10)

    /// Vendor 0x0e-prefixed controls: `0x0e` + (command `0xYY`).
    case blackEqualizer  // 0x0e00 (0-20)
    case colourMode      // 0x0e03 (0 cool, 1 normal, 2 warm, 3 user-defined)
    case rgbRed          // 0x0e04 (0-100)
    case rgbGreen        // 0x0e05 (0-100)
    case rgbBlue         // 0x0e06 (0-100)
    case gamma           // 0x0e07 (0 off, 1=1.8 ... 5=2.6)
    case vibrance        // 0x0e08 (0-20)
    case overdrive       // 0x0e09 (0 quality, 1 balance, 2 speed)
    case lowBlueLight    // 0x0e0b (0-10)
    case freeSync        // 0x0e0c (0 off, 1 on)
    case pbpPipMode      // 0x0e0e (0 off, 1 PIP, 2 PBP)
    case pbpPipSource    // 0x0e0f (0 HDMI1, 1 HDMI2, 2 DP, 3 Type-C)
    case pbpPipSwitch    // 0x0e10 (use 1)
    case pipSize         // 0x0e14 (0 large, 1 medium, 2 small)
    case pipLocation     // 0x0e15 (0 TL, 1 TR, 2 BL, 3 BR)
    case pipAudioSwitch  // 0x0e13 (use 1)
    case pictureMode     // 0x0e2c (0 standard, 1 FPS, 2 RTS/RPG, 3 Movie, 4 Reader, 5 sRGB, 6-8 custom)
    case source          // 0x0e2d (0 HDMI1, 1 HDMI2, 2 DP, 3 Type-C)
    case audioInput      // 0x0e2e (0 main, 1 PIP/PBP, 2 auto)
    case osdDisplayTime  // 0x0e30 (see table in MonitorCommand)
    case ledIndicator    // 0x0e31 (0 always on, 1 always off, 2 standby on)
    case kvmSwitch       // 0x0e69

    public var commandWord: UInt16 {
        switch self {
        case .brightness: return 0x0010
        case .contrast:   return 0x0012
        case .volume:     return 0x0062
        case .sharpness:  return 0x0087
        case .blackEqualizer: return 0xe000
        case .colourMode:     return 0xe003
        case .rgbRed:         return 0xe004
        case .rgbGreen:       return 0xe005
        case .rgbBlue:        return 0xe006
        case .gamma:          return 0xe007
        case .vibrance:       return 0xe008
        case .overdrive:      return 0xe009
        case .lowBlueLight:   return 0xe00b
        case .freeSync:       return 0xe00c
        case .pbpPipMode:     return 0xe00e
        case .pbpPipSource:   return 0xe00f
        case .pbpPipSwitch:   return 0xe010
        case .pipSize:        return 0xe014
        case .pipLocation:    return 0xe015
        case .pipAudioSwitch: return 0xe013
        case .pictureMode:    return 0xe02c
        case .source:         return 0xe02d
        case .audioInput:     return 0xe02e
        case .osdDisplayTime: return 0xe030
        case .ledIndicator:   return 0xe031
        case .kvmSwitch:      return 0xe069
        }
    }

    /// The standard MCCS VCP code for this control, if it is an
    /// over-the-cable DDC/CI control. Controls that write via the vendor
    /// 0x0eXX HID path (KVM, PBP/PIP, picture modes, colour, …) return nil.
    ///
    /// Standard VCP controls (brightness/contrast/volume/sharpness) MUST be
    /// written over the video-cable DDC channel, NOT the USB HID controller —
    /// the Realtek HID controller only applies vendor 0x0eXX commands and
    /// ignores standard DDC opcodes sent through it (verified live on the
    /// CO49DQ).
    public var standardVCP: DisplayVCP? {
        switch self {
        case .brightness: return .luminance
        case .contrast:   return .contrast
        case .volume:     return .speakerVolume
        case .sharpness:  return .sharpness
        default:          return nil
        }
    }

    /// Human-readable label for CLI help / status output.
    public var label: String {
        switch self {
        case .brightness:      return "brightness"
        case .contrast:        return "contrast"
        case .volume:          return "volume"
        case .sharpness:       return "sharpness"
        case .blackEqualizer:  return "black-equalizer"
        case .colourMode:      return "colour-mode"
        case .rgbRed:          return "rgb-red"
        case .rgbGreen:        return "rgb-green"
        case .rgbBlue:         return "rgb-blue"
        case .gamma:           return "gamma"
        case .vibrance:        return "vibrance"
        case .overdrive:       return "overdrive"
        case .lowBlueLight:    return "low-blue-light"
        case .freeSync:        return "free-sync"
        case .pbpPipMode:      return "pbp-pip-mode"
        case .pbpPipSource:    return "pbp-pip-source"
        case .pbpPipSwitch:    return "pbp-pip-switch"
        case .pipSize:         return "pip-size"
        case .pipLocation:     return "pip-location"
        case .pipAudioSwitch:  return "pip-audio-switch"
        case .pictureMode:     return "picture-mode"
        case .source:          return "source"
        case .audioInput:      return "audio-input"
        case .osdDisplayTime:  return "osd-display-time"
        case .ledIndicator:    return "led-indicator"
        case .kvmSwitch:       return "kvm-switch"
        }
    }

    /// Valid value range (to guard against garbage input).
    public var range: ClosedRange<UInt16> {
        switch self {
        case .brightness, .contrast, .volume, .rgbRed, .rgbGreen, .rgbBlue:
            return 0...100
        case .sharpness:      return 0...10
        case .blackEqualizer: return 0...20
        case .colourMode:     return 0...3
        case .gamma:          return 0...5
        case .vibrance:       return 0...20
        case .overdrive:      return 0...2
        case .lowBlueLight:   return 0...10
        case .freeSync:       return 0...1
        case .pbpPipMode:     return 0...2
        case .pbpPipSource:   return 0...3
        case .pbpPipSwitch:   return 0...9
        case .pipSize:        return 0...2
        case .pipLocation:    return 0...3
        case .pipAudioSwitch: return 0...9
        case .pictureMode:    return 0...8
        case .source:         return 0...3
        case .audioInput:     return 0...2
        case .osdDisplayTime: return 0...5
        case .ledIndicator:   return 0...2
        case .kvmSwitch:      return 0...1
        }
    }
}

/// Common pre-set convenience values (human-readable aliases → raw ints).
public enum PresetValue {
    public enum ColourTemperature: UInt16 {
        case cool = 0, normal = 1, warm = 2, userDefined = 3
    }
    public enum Input: UInt16 {
        case hdmi1 = 0, hdmi2 = 1, dp = 2, typeC = 3
    }
    public enum PbpPipMode: UInt16 {
        case off = 0, pip = 1, pbp = 2
    }
    public enum PictureMode: UInt16 {
        case standard = 0, fps = 1, rtsRpg = 2, movie = 3, reader = 4, sRGB = 5, custom1 = 6, custom2 = 7, custom3 = 8
    }
    public enum KVM: UInt16 {
        case usbB = 0, typeC = 1
    }
}
