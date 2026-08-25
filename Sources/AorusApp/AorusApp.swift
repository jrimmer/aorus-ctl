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

    init() {
        // The default macOS help-tag delay (~0.5-1s) feels sluggish for toggle
        // hints. Shorten it so the `.help()` tooltip appears promptly (~0.15s).
        // NSInitialToolTipDelay is in milliseconds and is app-wide.
        UserDefaults.standard.set(150, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        MenuBarExtra("Aorus", systemImage: "display") {
            ControlsPanel()
                .environmentObject(store)
                .frame(width: 320)
                .onAppear { registerHotkeys() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }

    /// Registers the system-wide hotkeys once. Retained so the Carbon refs stay
    /// alive; also guards against double registration on re-appear.
    @MainActor
    func registerHotkeys() {
        guard hotkeyManager == nil else { return }
        let manager = HotkeyManager(
            onCyclePbpPip: { [weak store] in store?.cyclePbpPipMode() },
            onSwap: { [weak store] in store?.swapSources() }
        )
        manager.register()
        hotkeyManager = manager
    }

    @State private var hotkeyManager: HotkeyManager?
}
