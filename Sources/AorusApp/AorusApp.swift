import SwiftUI
import AorusCore

/// Aorus — menu-bar control for Gigabyte/AORUS monitors over USB HID.
///
/// Zero-dependency SwiftUI menu-bar app wrapping `AorusCore`. Because the
/// CO49DQ HID controller is write-only (see docs/protocol.md), controls are
/// driven directly by user interaction; the app tracks last-known values
/// rather than polling the monitor.
///
/// Run locally with:
///   swift run AorusApp
/// (Optionally build a .app bundle with `swift build -c release` + wrapping.)
@main
struct AorusApp: App {
    @StateObject private var store = MonitorStore()

    var body: some Scene {
        MenuBarExtra("Aorus", systemImage: "display") {
            ControlsPanel()
                .environmentObject(store)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
