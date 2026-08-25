import SwiftUI
import AorusCore

/// The Settings scene (⌘,). Exposes connection / reconnect controls, a
/// one-tap cable-DDC value refresh, and an about note.
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
                HStack {
                    Button(store.isConnected ? "Reconnect" : "Connect") {
                        store.connect()
                    }
                    if store.isConnected {
                        Button("Read real values") {
                            store.refreshFromDDC()
                        }
                    }
                }
            }

            Section("About") {
                Text("""
                Aorus — native macOS menu-bar control for Gigabyte/AORUS monitors over USB HID.

                Writes speak the vendor protocol of the Realtek HID controller
                (VID 0x0bda / PID 0x1100) that OSD Sidekick uses on Windows. Reads
                of standard values (luminance, contrast, volume, sharpness) come
                from the monitor's real DDC/CI state over the video cable.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}
