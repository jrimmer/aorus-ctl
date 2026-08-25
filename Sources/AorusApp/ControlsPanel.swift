import SwiftUI
import AorusCore

/// The menu-bar dropdown panel. Top to bottom:
/// connection status, display sliders, KVM/input, PBP-PIP, picture modes, color.
struct ControlsPanel: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.isConnected {
                // The sections are a fixed, known set. We leave them as a
                // plain VStack (not a ScrollView — which has no intrinsic
                // height and collapses the window) so the MenuBarExtra(.window)
                // hugs the panel's natural content height exactly, with no top
                // gap and no empty space below.
                VStack(alignment: .leading, spacing: 16) {
                    DisplaySection()
                    InputSection()
                    PbpSection()
                    PictureSection()
                    ColorSection()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { store.connect() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Aorus", systemImage: "display")
                .font(.headline)

            if store.isConnected {
                // Connected indicator sits right next to the monitor title;
                // Refresh to its right, then a spacer pushes Quit to the edge.
                Label("Connected", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button {
                    store.refreshFromDDC()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read real values over cable-DDC")
            }

            Spacer()

            if !store.isConnected {
                Button {
                    store.connect()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            // Quit the menu-bar app.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Quit Aorus")
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sections

/// Brightness / contrast / volume sliders.
private struct DisplaySection: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Display")
            SliderRow(label: "Brightness", icon: "sun.max.fill",
                      control: .brightness,
                      value: store.values[.brightness] ?? 50)
            SliderRow(label: "Contrast", icon: "circle.lefthalf.filled",
                      control: .contrast,
                      value: store.values[.contrast] ?? 50)
            SliderRow(label: "Volume", icon: "speaker.wave.2.fill",
                      control: .volume,
                      value: store.values[.volume] ?? 50)
        }
    }
}

/// Generic labelled slider bound to a 0-100 control.
private struct SliderRow: View {
    let label: String
    let icon: String
    let control: MonitorControl
    let value: UInt16

    @EnvironmentObject var store: MonitorStore

    var body: some View {
        // A Double binding that writes through the store (values has a
        // private(set) setter, and the slider must go via `set` anyway).
        let binding = Binding<Double>(
            get: { Double(store.values[control] ?? 0) },
            set: { newValue in store.set(control, value: UInt16(newValue.rounded())) }
        )
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .frame(width: 70, alignment: .leading)
            Slider(value: binding, in: 0...100, step: 1)
            Text("\(store.values[control] ?? 0)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// KVM upstream + video input source.
private struct InputSection: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Input & KVM")

            MenuPicker<PresetValue.Input>(
                label: "Video input",
                control: .source,
                key: .source,
                options: [
                    (.hdmi1, "HDMI 1"),
                    (.hdmi2, "HDMI 2"),
                    (.dp, "DisplayPort"),
                    (.typeC, "USB-C"),
                ]
            )

            MenuPicker<PresetValue.KVM>(
                label: "KVM upstream",
                control: .kvmSwitch,
                key: .kvmSwitch,
                options: [
                    (.usbB, "USB-B"),
                    (.typeC, "USB-C"),
                ]
            )
        }
    }
}

/// PBP / PIP multi-picture configuration.
private struct PbpSection: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("PBP / PIP")

            MenuPicker<PresetValue.PbpPipMode>(
                label: "Mode",
                control: .pbpPipMode,
                key: .pbpPipMode,
                options: [
                    (.off, "Off"),
                    (.pip, "PIP"),
                    (.pbp, "PBP"),
                ]
            )

            if (store.values[.pbpPipMode] ?? 0) != 0 {
                MenuPicker<PresetValue.Input>(
                    label: "Second source",
                    control: .pbpPipSource,
                    key: .pbpPipSource,
                    options: [
                        (.hdmi1, "HDMI 1"),
                        (.hdmi2, "HDMI 2"),
                        (.dp, "DisplayPort"),
                        (.typeC, "USB-C"),
                    ]
                )

                // Swap the two PBP/PIP inputs at the monitor. Uses the native
                // vendor swap opcode (0xe0 0x10 = 1), which exchanges the
                // physical sides in PBP and the primary/secondary inputs in PIP
                // WITHOUT re-assigning the source values (the earlier manual
                // re-assignment produced a mirror).
                Button {
                    store.set(.pbpPipSwitch, value: 1)
                } label: {
                    Label("Swap sides", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap the two PBP/PIP inputs at the monitor")
            }

            if (store.values[.pbpPipMode] ?? 0) == 1 {
                MenuPicker<PresetValue.PipSize>(
                    label: "PIP size",
                    control: .pipSize,
                    key: .pipSize,
                    options: [
                        (.large, "Large"),
                        (.medium, "Medium"),
                        (.small, "Small"),
                    ]
                )
                MenuPicker<PresetValue.PipLocation>(
                    label: "PIP location",
                    control: .pipLocation,
                    key: .pipLocation,
                    options: [
                        (.topLeft, "Top-left"),
                        (.topRight, "Top-right"),
                        (.bottomLeft, "Bottom-left"),
                        (.bottomRight, "Bottom-right"),
                    ]
                )
            }
        }
    }
}

/// Picture modes and simple on/off colour-affecting toggles.
private struct PictureSection: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Picture modes")

            MenuPicker<PresetValue.PictureMode>(
                label: "Mode",
                control: .pictureMode,
                key: .pictureMode,
                options: [
                    (.standard, "Standard"),
                    (.fps, "FPS"),
                    (.rtsRpg, "RTS/RPG"),
                    (.movie, "Movie"),
                    (.reader, "Reader"),
                    (.sRGB, "sRGB"),
                    (.custom1, "Custom 1"),
                    (.custom2, "Custom 2"),
                    (.custom3, "Custom 3"),
                ]
            )

            Toggle("FreeSync", isOn: boolBinding(for: .freeSync))
            Toggle("Low blue light", isOn: boolBinding(for: .lowBlueLight))
        }
    }

    /// Adapts a 0/1 on/off control to a SwiftUI Toggle binding.
    private func boolBinding(for control: MonitorControl) -> Binding<Bool> {
        Binding<Bool>(
            get: { (store.values[control] ?? 0) != 0 },
            set: { newValue in
                store.set(control, value: newValue ? 1 : 0)
            }
        )
    }
}

/// Per-channel RGB (when colour-mode = user) + vibrance.
private struct ColorSection: View {
    @EnvironmentObject var store: MonitorStore

    private var rgbEnabled: Bool {
        (store.values[.colourMode] ?? 0) == 3 // user-defined
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Colour")

            MenuPicker<PresetValue.ColourTemperature>(
                label: "Temperature",
                control: .colourMode,
                key: .colourMode,
                options: [
                    (.cool, "Cool"),
                    (.normal, "Normal"),
                    (.warm, "Warm"),
                    (.userDefined, "User-defined"),
                ]
            )

            if rgbEnabled {
                SliderRow(label: "Red", icon: "circle.fill",
                          control: .rgbRed, value: store.values[.rgbRed] ?? 50)
                    .foregroundStyle(.red)
                SliderRow(label: "Green", icon: "circle.fill",
                          control: .rgbGreen, value: store.values[.rgbGreen] ?? 50)
                SliderRow(label: "Blue", icon: "circle.fill",
                          control: .rgbBlue, value: store.values[.rgbBlue] ?? 50)
            } else {
                Text("Select a temperature to tune per-channel RGB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SliderRow(label: "Vibrance", icon: "paintpalette.fill",
                      control: .vibrance, value: store.values[.vibrance] ?? 10)
        }
    }
}

// MARK: - Shared building blocks

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }
}

/// A picker fed by raw `UInt16` values, labelled and bound to a monitor control.
private struct MenuPicker<E: RawRepresentable>: View where E.RawValue == UInt16 {
    let label: String
    let control: MonitorControl
    let key: MonitorControl
    let options: [(E, String)]

    @EnvironmentObject var store: MonitorStore

    var body: some View {
        let current = store.values[key] ?? control.range.lowerBound
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Spacer()
            Picker("", selection: Binding<UInt16>(
                get: { current },
                set: { store.set(key, value: $0) }
            )) {
                ForEach(options, id: \.1) { option in
                    Text(option.1).tag(option.0.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
        }
        .controlSize(.small)
    }
}
