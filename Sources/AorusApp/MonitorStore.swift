import Foundation
import AorusCore

/// A reference-based, thread-safe wrapper around `MonitorController` for the
/// SwiftUI menu-bar app.
///
/// Design notes:
/// - **Reads are not supported** on the CO49DQ's HID controller (verified on
///   hardware; see docs/protocol.md). So the store does **not** fetch current
///   values — it tracks the values this session applied and defaults controls to
///   safe mid-range values. Writes are treated as authoritative.
/// - All I/O goes through a serial `DispatchQueue` so interactions on the main
///   actor don't block the UI and concurrent writes are serialized.
@MainActor
public final class MonitorStore: ObservableObject {

    /// Controls this app surfaces, with an initial safe value.
    static let initialValues: [MonitorControl: UInt16] = [
        .brightness: 50,
        .contrast: 50,
        .volume: 50,
        .sharpness: 5,
        .colourMode: 1,          // normal
        .gamma: 0,               // off
        .vibrance: 10,
        .overdrive: 1,           // balance
        .pbpPipMode: 0,          // off
        .pbpPipSource: 3,        // Type-C
        .pictureMode: 0,         // standard
        .source: 3,              // Type-C
        .kvmSwitch: 1,           // Type-C
    ]

    // MARK: Published state

    /// Current (last-applied or default) values for each control.
    @Published public private(set) var values: [MonitorControl: UInt16]
    /// Whether the monitor's HID control device was found and opened.
    @Published public private(set) var isConnected = false
    /// Human-readable error surfaced to the panel, if any.
    @Published public private(set) var statusMessage: String?

    private let ioQueue = DispatchQueue(label: "aorus.app.io", qos: .userInitiated)
    private var controller: MonitorController?

    public init() {
        self.values = Self.initialValues
    }

    /// Attempts to open the monitor control device. Called on app launch and
    /// from the panel (e.g. a Retry button).
    public func connect() {
        guard controller == nil else { return }
        do {
            let monitor = try MonitorController.openFirst()
            self.controller = monitor
            self.isConnected = true
            self.statusMessage = "Connected"
        } catch {
            self.isConnected = false
            self.statusMessage = "No monitor found. Is the USB upstream connected?"
        }
    }

    /// Disconnect and drop the open handle so the USB device can be re-sent.
    public func disconnect() {
        self.controller = nil
        self.isConnected = false
    }

    /// Writes `value` to `control`, recording it optimistically and updating
    /// last-known state. Serialized on `ioQueue`.
    @discardableResult
    public func set(_ control: MonitorControl, value: UInt16) -> Bool {
        // Clamp to the control's valid range before storing/sending.
        let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
        if let monitor = controller {
            ioQueue.async { [weak self] in
                do {
                    try monitor.set(control, value: clamped)
                } catch {
                    Task { @MainActor in
                        self?.statusMessage = "Write to \(control.label) failed"
                    }
                }
            }
        }
        self.values[control] = clamped
        return controller != nil
    }
}
