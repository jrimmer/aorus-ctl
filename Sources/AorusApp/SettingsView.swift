import SwiftUI
import AorusCore

/// The Settings scene (⌘,). Currently exposes connection / reconnect controls
/// and a short "about + caveat" blurb. The app is intentionally write-only
/// because the CO49DQ HID controller provides no status read-back.
struct SettingsView: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        Form {
            Section("Monitor") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(store.statusMessage ?? "Not connected")
                        .foregroundStyle(store.isConnected ? .green : .secondary)
                }
                Button(store.isConnected ? "Reconnect" : "Connect") {
                    store.connect()
                }
            }

            Section("About") {
                Text("""
                Aorus — native macOS menu-bar control for Gigabyte/AORUS monitors over USB HID.

                Speaks the vendor protocol of the Realtek HID controller (VID 0x0bda / PID 0x1100) that OSD Sidekick uses on Windows.

                Note: this controller is write-only; the app tracks last-known settings rather than reading them back.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }
}
