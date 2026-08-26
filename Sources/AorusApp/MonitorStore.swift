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
        .pipSize: 0,             // large
        .pipLocation: 0,         // top-left
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
    private var ddcReader: DDCReader?

    /// Background auto-reconnect loop, started when the HID control endpoint
    /// drops off the bus. Cancelled (set to nil) on a successful reconnect or a
    /// manual disconnect/connect. Only one loop runs at a time.
    private var reconnectTask: Task<Void, Never>?
    private var isAutoReconnecting = false
    /// Upper bound on automatic reconnect attempts before giving up and
    /// asking the user to reconnect manually (avoids an infinite background
    /// poll). Between attempts we back off.
    private let maxReconnectAttempts = 60
    private let reconnectIntervalNanoseconds: UInt64 = 2_000_000_000 // 2s

    /// Backing defaults store; injectable for tests.
    private let defaults: UserDefaults

    /// UserDefaults key prefix for persisting last-known control values.
    /// Persistence lets the app remember the monitor's true vendor-control state
    /// (PBP/PIP mode, KVM, picture mode, sources, …) across launches, since the
    /// CO49DQ provides no read-back for those controls (the HID controller is
    /// write-only and cable-DDC does not serve vendor feature reads).
    private static let defaultsPrefix = "aorus.lastKnown."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Restore last-known values (persisted on each set) before falling back
        // to safe defaults, so vendor controls reflect what we previously
        // applied rather than a guessed default.
        var loaded = Self.initialValues
        for control in loaded.keys {
            let key = Self.defaultsPrefix + control.label
            if defaults.object(forKey: key) != nil {
                loaded[control] = UInt16(defaults.integer(forKey: key))
            }
        }
        self.values = loaded
    }

    /// Attempts to open the monitor control device. Called on app launch and
    /// from the panel (e.g. a Retry button). Also seeds brightness/contrast/
    /// volume/sharpness from the *cable-DDC* read, which is the only path that
    /// reports real current values (the HID controller is write-only).
    public func connect() {
        // A manual connect supersedes any background auto-reconnect loop.
        stopAutoReconnect()
        endAutoReconnectState()
        if controller == nil {
            do {
                let monitor = try MonitorController.openFirst()
                self.controller = monitor
                self.isConnected = true
                self.statusMessage = "Connected"
            } catch {
                self.isConnected = false
                self.statusMessage = "No monitor found. Waiting for the USB upstream…"
                // If the device might just be momentarily absent, start the
                // auto-reconnect loop so it comes up on its own.
                startAutoReconnect()
                return
            }
        }
        refreshFromDDC()
    }

    /// Re-reads brightness/contrast/volume/sharpness over cable-DDC and updates
    /// the tracked values so the UI shows the monitor's *actual* state.
    public func refreshFromDDC() {
        guard isConnected else { self.statusMessage = "Not connected"; return }
        if ddcReader == nil { ddcReader = DDCReader() }
        guard let reader = ddcReader else {
            self.statusMessage = "Connected (cable-DDC reads unavailable)"
            return
        }
        ioQueue.async { [weak self] in
            let mapping: [(MonitorControl, DisplayVCP)] = [
                (.brightness, .luminance),
                (.contrast, .contrast),
                (.volume, .speakerVolume),
                (.sharpness, .sharpness),
            ]
            for (control, vcp) in mapping {
                if let reading = reader.read(vcp) {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.values[control] = reading.current
                        self.defaults.set(Int(reading.current), forKey: Self.defaultsPrefix + control.label)
                    }
                }
            }
        }
    }

    /// Disconnect and drop the open handle so the USB device can be re-sent.
    public func disconnect() {
        stopAutoReconnect()
        endAutoReconnectState()
        self.controller = nil
        self.isConnected = false
    }

    /// Handles a failed write. If the HID endpoint has dropped off the bus
    /// (the CO49DQ's USB upstream can vanish while video stays up, e.g. after
    /// an input/PBP-PIP re-route), flip to a disconnected state and start an
    /// **automatic** reconnect loop that retries until the device returns.
    /// If the device is still present (a transient STALL), retry the same
    /// write a couple of times before surfacing an error. Called from the main
    /// actor; bus enumeration is done off-thread.
    @MainActor
    private func handleWriteFailure(_ control: MonitorControl, _ value: UInt16, _ message: String) {
        ioQueue.async { [weak self] in
            let present = MonitorController.isDevicePresent()
            Task { @MainActor [weak self, present, control, value, message] in
                guard let self else { return }
                if !present {
                    // Device genuinely gone: reflect it, drop the stale
                    // handle, and start auto-reconnect.
                    self.controller = nil
                    self.isConnected = false
                    self.statusMessage = "Monitor offline — reconnecting…"
                    self.startAutoReconnect()
                } else {
                    // Device still there: this is a transient STALL (or a stale
                    // handle). Retry the write once, and only surface an error
                    // if it fails again.
                    self.retryWrite(control, value, originalMessage: message)
                }
            }
        }
    }

    /// Re-attempts a single control write after a transient failure. If it
    /// succeeds, clears the error; otherwise surfaces the message.
    @MainActor
    private func retryWrite(_ control: MonitorControl, _ value: UInt16, originalMessage: String) {
        guard let monitor = controller else {
            statusMessage = originalMessage
            return
        }
        do {
            try monitor.set(control, value: value)
            statusMessage = "Connected"
        } catch {
            statusMessage = originalMessage
        }
    }

    /// Starts the background auto-reconnect loop (idempotent — only one loop
    /// runs at a time). Polls for the HID device; once present, re-opens it,
    /// reconnects, refreshes cable-DDC values, and stops. Gives up after
    /// `maxReconnectAttempts` to avoid an infinite background poll.
    ///
    /// Note: the immutable counters are captured as local `let`s so the
    /// detached task never reads main-actor-isolated state synchronously
    /// (which the older CI compiler flags as a data race).
    private func startAutoReconnect() {
        guard !isAutoReconnecting else { return }
        isAutoReconnecting = true
        reconnectTask?.cancel()
        let maxAttempts = maxReconnectAttempts
        let interval = reconnectIntervalNanoseconds
        reconnectTask = Task.detached { [weak self] in
            var attempts = 0
            while !Task.isCancelled && attempts < maxAttempts {
                // Main-actor-free presence check off the hot path.
                if MonitorController.isDevicePresent() {
                    let didReconnect = await self?.attemptReconnect() ?? false
                    if didReconnect {
                        return
                    }
                }
                attempts += 1
                try? await Task.sleep(nanoseconds: interval)
            }
            // Gave up: ask the user to reconnect manually.
            await self?.finishAutoReconnect(success: false)
        }
    }

    /// Attempts to re-open the device after it reappeared on the bus. Returns
    /// true if the handle was re-established.
    @MainActor
    private func attemptReconnect() -> Bool {
        do {
            let monitor = try MonitorController.openFirst()
            self.controller = monitor
            self.isConnected = true
            self.statusMessage = "Connected"
            stopAutoReconnect()
            endAutoReconnectState()
            refreshFromDDC()
            return true
        } catch {
            // Still absent or failed: keep polling.
            return false
        }
    }

    /// Ends the auto-reconnect loop.
    private func stopAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Resets the auto-reconnect in-flight guard so a fresh loop can start.
    private func endAutoReconnectState() {
        isAutoReconnecting = false
    }

    /// Marks a gave-up auto-reconnect (the loop hit its retry cap) so the
    /// panel asks the user to reconnect manually.
    @MainActor
    private func finishAutoReconnect(success: Bool) {
        endAutoReconnectState()
        if !success {
            self.statusMessage = "Couldn't reconnect. Check the USB upstream and click Retry."
        }
    }

    /// Writes `value` to `control`, recording it optimistically and updating
    /// last-known state. Serialized on `ioQueue`.
    ///
    /// When activating PBP/PIP (pbpPipMode != 0), the monitor applies the mode
    /// using whatever inputs are set *at that instant*, so the two sources must
    /// be written BEFORE the mode flips on. We therefore enqueue `.source` and
    /// `.pbpPipSource` ahead of the mode write on the serial queue (matching the
    /// proven CLI order: source, second source, then mode).
    @discardableResult
    public func set(_ control: MonitorControl, value: UInt16) -> Bool {
        // Clamp to the control's valid range before storing/sending.
        let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
        // When activating PBP/PIP, the monitor applies the mode using whatever
        // inputs are set at that instant, so capture the two source values the
        // app wants BEFORE dispatching so they can be written ahead of the mode
        // on the serial queue.
        let primarySource = values[.source] ?? 0
        let secondSource = values[.pbpPipSource] ?? 0
        if let monitor = controller {
            ioQueue.async { [weak self] in
                // Push the two sources first so the monitor uses them the
                // moment it enters the mode (proven CLI order: source, second
                // source, then mode).
                if control == .pbpPipMode && clamped != 0 {
                    let orderedSources: [(MonitorControl, UInt16)] = [
                        (.source, primarySource),
                        (.pbpPipSource, secondSource),
                    ]
                    for (sourceControl, sourceValue) in orderedSources {
                        do { try monitor.set(sourceControl, value: sourceValue) }
                        catch {
                            let message = "Write to \(sourceControl.label) failed"
                            Task { @MainActor [weak self, sourceControl, sourceValue, message] in
                                self?.handleWriteFailure(sourceControl, sourceValue, message)
                            }
                        }
                    }
                }
                do {
                    try monitor.set(control, value: clamped)
                } catch {
                    let message = "Write to \(control.label) failed"
                    Task { @MainActor [weak self, control, clamped, message] in
                        self?.handleWriteFailure(control, clamped, message)
                    }
                }
            }
        }
        self.values[control] = clamped
        // Persist the last-known value so vendor controls (which have no
        // read-back) are restored accurately on the next launch.
        self.defaults.set(Int(clamped), forKey: Self.defaultsPrefix + control.label)
        return controller != nil
    }

    /// Cycles PBP/PIP mode through its three states: Off → PIP → PBP → Off.
    public func cyclePbpPipMode() {
        let current = values[.pbpPipMode] ?? 0
        let next = (current + 1) % 3
        set(.pbpPipMode, value: next)
    }

    /// Swaps the two PBP/PIP inputs at the monitor via the native vendor swap
    /// opcode (0xe0 0x10 = 1).
    public func swapSources() {
        set(.pbpPipSwitch, value: 1)
    }
}
