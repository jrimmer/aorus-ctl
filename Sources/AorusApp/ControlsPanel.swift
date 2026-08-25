import SwiftUI
import AppKit
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
        .fixedSize(horizontal: false, vertical: true)
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
            NativeSlider(value: binding)
            Text("\(store.values[control] ?? 0)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// A native AppKit `NSSlider` wrapped for SwiftUI — the stock macOS slider
/// with no tick marks, so it looks like any other system slider. Continuous so
/// the monitor updates live as the knob is dragged.
private struct NativeSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value, minValue: 0, maxValue: 100,
            target: context.coordinator, action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    @MainActor
    final class Coordinator: NSObject {
        private let value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
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
            HStack(spacing: 6) {
                SectionTitle("PBP / PIP")
                // A "?" glyph signals a hover tooltip; the tooltip itself is
                // presented via .help() (AppKit-anchored, reliable inside the
                // MenuBarExtra window, unlike a .popover which gets centered).
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("\u{2318}\u{21e7}P  Cycle PBP/PIP mode\n\u{2318}\u{21e7}X  Swap the PBP/PIP inputs")
            }

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
                // The two sources are full-width dropdown rows (label on the
                // left, picker on the right), matching the rest of the panel.
                MenuPicker<PresetValue.Input>(
                    label: "Source",
                    control: .source,
                    key: .source,
                    options: [
                        (.hdmi1, "HDMI 1"),
                        (.hdmi2, "HDMI 2"),
                        (.dp, "DisplayPort"),
                        (.typeC, "USB-C"),
                    ]
                )
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

                // Switch swaps the two PBP/PIP inputs via the native vendor
                // swap opcode (0xe0 0x10 = 1), which exchanges the physical
                // PBP sides / PIP primary-secondary inputs without re-assigning
                // the source values. It's a centred action button below the
                // sources, distinct from the dropdowns.
                Button {
                    store.set(.pbpPipSwitch, value: 1)
                } label: {
                    Label("Switch inputs", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 2)
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

            toggleRow(label: "FreeSync", isOn: boolBinding(for: .freeSync))
            toggleRow(label: "Low blue light", isOn: boolBinding(for: .lowBlueLight))
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

    /// A toggle row whose label sits left (flush with the dropdown labels) and
    /// whose switch aligns its LEFT edge with the left edge of the dropdown
    /// picker boxes — so the switch sits slightly inward rather than flush
    /// against the far edge.
    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 170, alignment: .leading)
        }
        .controlSize(.small)
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
            .frame(maxWidth: 170, alignment: .trailing)
        }
        .controlSize(.small)
    }
}

