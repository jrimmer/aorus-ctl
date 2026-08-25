//
//  main.swift
//  aorusctl
//
//  Native macOS control for Gigabyte/AORUS monitors over USB HID.
//
//  Usage:
//    aorusctl list                       Discover monitor control devices
//    aorusctl set <prop> <value>          Set a property (see list below)
//    aorusctl props                       List all known properties + ranges
//    aorusctl dump                        Dump raw 193-byte status report
//    aorusctl --dry-run set <prop> <val>  Print the report bytes, don't send
//
import Foundation
import AorusCore

// MARK: - Argument parsing (dependency-free)

struct Options {
    var dryRun = false
    var command: String = ""
    var args: [String] = []
}

func parseArgs(_ argv: [String]) -> (Options, [String]) {
    var opts = Options()
    var rest: [String] = []
    var index = 0
    while index < argv.count {
        let arg = argv[index]
        switch arg {
        case "--dry-run", "-n":
            opts.dryRun = true
        case "--help", "-h":
            opts.command = "help"
        default:
            if opts.command.isEmpty {
                opts.command = arg
            } else {
                rest.append(arg)
            }
        }
        index += 1
    }
    opts.args = rest
    return (opts, rest)
}

func printUsage() {
    print("""
    aorusctl — control Gigabyte/AORUS monitors over USB HID

    USAGE:
      aorusctl list                          Discover monitor control devices
      aorusctl set <property> <value>        Set a property on the monitor
      aorusctl get <property>                Read a property via cable-DDC (brightness/contrast/volume/sharpness)
      aorusctl props                         List all known properties + ranges
      aorusctl dump                          Dump the raw status report (hex, ⚠ experimental)
      aorusctl --dry-run set <p> <v>         Print report bytes without sending (DANGER: still opens device read-only — safe)

    Use '-n' / '--dry-run' with 'set' to see exactly which bytes would be sent.

    KNOWN PROPERTIES:
    """)
    let all: [MonitorControl] = [
        .brightness, .contrast, .volume, .sharpness,
        .blackEqualizer, .colourMode, .rgbRed, .rgbGreen, .rgbBlue,
        .gamma, .vibrance, .overdrive, .lowBlueLight, .freeSync,
        .pbpPipMode, .pbpPipSource, .pbpPipSwitch, .pipSize, .pipLocation,
        .pipAudioSwitch, .pictureMode, .source, .audioInput,
        .osdDisplayTime, .ledIndicator, .kvmSwitch,
    ]
    for control in all {
        print(String(format: "  %-18@ %d-%d", control.label as NSString, control.range.lowerBound, control.range.upperBound))
    }
    print("""

    NOTES:
      * To enable monitor control, connect the monitor's USB upstream
        (USB-B on this model's USB upstream port) to your Mac.
      * The vendor codes for KVM switching: set kvm-switch to 0 (USB-B) or 1 (Type-C).
    """)
}

// MARK: - Property registry

func allControls() -> [MonitorControl] {
    [
        .brightness, .contrast, .volume, .sharpness,
        .blackEqualizer, .colourMode, .rgbRed, .rgbGreen, .rgbBlue,
        .gamma, .vibrance, .overdrive, .lowBlueLight, .freeSync,
        .pbpPipMode, .pbpPipSource, .pbpPipSwitch, .pipSize, .pipLocation,
        .pipAudioSwitch, .pictureMode, .source, .audioInput,
        .osdDisplayTime, .ledIndicator, .kvmSwitch,
    ]
}

func control(for name: String) -> MonitorControl? {
    allControls().first { $0.label == name }
}

// MARK: - Commands

func run(_ opts: Options) {
    switch opts.command {
    case "list":
        let devices = findMonitorDevices()
        if devices.isEmpty {
            print("No Realtek 0bda:1100 HID device found.")
            print("If your monitor uses a different controller, try `aorusctl list --all` (not yet added) or connect the USB upstream.")
            return
        }
        print("Found \(devices.count) monitor control device(s):")
        for device in devices {
            print("  \(device.description)")
        }
        return

    case "props":
        for control in allControls() {
            print(String(format: "  %-18@ %d-%d", control.label as NSString, control.range.lowerBound, control.range.upperBound))
        }
        return

    case "set":
        guard opts.args.count >= 2 else {
            print("ERROR: `set` requires a property and a value.\n  e.g. aorusctl set brightness 50")
            return
        }
        let propName = opts.args[0]
        let valueStr = opts.args[1]
        guard let control = control(for: propName) else {
            print("ERROR: unknown property '\(propName)'. Run `aorusctl props` for the list.")
            return
        }
        guard let value = UInt16(valueStr) else {
            print("ERROR: value '\(valueStr)' is not a number.")
            return
        }
        do {
            let report = try ReportBuilder.buildReport(control: control, value: value)
            if opts.dryRun {
                print("Dry run — report bytes that would be sent:")
                print(hexDump(report))
                print("(Not sent. Remove --dry-run to actually apply.)")
                return
            }
            let controller = try MonitorController.openFirst()
            try controller.set(control, value: value)
            print("Set \(control.label) to \(value).")
        } catch {
            print("ERROR: \(error)")
        }

    case "get":
        // A real value read comes from the *video-cable DDC* channel. Standard
        // VCP controls (brightness/contrast/volume/sharpness) are read over
        // cable-DDC via the controller. Vendor features (PBP/PIP, KVM, picture
        // modes) have no read-back.
        guard opts.args.count >= 1, let control = control(for: opts.args[0]) else {
            print("ERROR: `get` requires a known property. Run `aorusctl props` first.")
            return
        }
        do {
            let controller = try MonitorController.openFirst()
            if let reading = controller.read(control) {
                print("\(control.label): \(reading.current) / \(reading.maximum)")
            } else {
                print("ERROR: `get \(control.label)` is not readable via DDC on this display.")
                print("  Cable-DDC reads are available for: brightness, contrast, volume, sharpness.")
                print("  The USB HID controller is write-only, so vendor features (PBP/PIP, KVM,")
                print("  picture modes) have no read-back. See docs/protocol.md §5.")
            }
        } catch {
            print("ERROR: \(error)")
        }

    case "dump":
        do {
            let controller = try MonitorController.openFirst()
            let blob = try controller.dumpStatus()
            print(hexDump(blob))
        } catch {
            print("ERROR: \(error)")
        }

    case "help":
        printUsage()

    default:
        printUsage()
    }
}

let (options, _) = parseArgs(Array(CommandLine.arguments.dropFirst()))
run(options)
