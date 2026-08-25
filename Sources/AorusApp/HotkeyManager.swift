import AppKit
import Carbon.HIToolbox
import AorusCore

/// Registers system-wide hotkeys (via Carbon `RegisterEventHotKey`) for the
/// menu-bar app so the monitor controls work even when the panel isn't focused.
///
/// Hotkeys:
///   * ⌘⇧P — cycle PBP/PIP mode (Off → PIP → PBP → Off)
///   * ⌘⇧X — swap the two PBP/PIP inputs
///   * ⌘Q  — quit the app
///
/// Carbon hotkeys are used rather than `NSEvent` global monitors so the keys
/// fire system-wide without requiring Accessibility permission.
@MainActor
final class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    /// Retained for the Carbon handler callback.
    private var selfRef: UnsafeMutableRawPointer?

    private let onCyclePbpPip: () -> Void
    private let onSwap: () -> Void

    /// `onCyclePbpPip` and `onSwap` are invoked on the main actor when the
    /// corresponding hotkey fires. Quit is handled internally via
    /// `NSApplication.shared.terminate`.
    init(
        onCyclePbpPip: @escaping () -> Void,
        onSwap: @escaping () -> Void
    ) {
        self.onCyclePbpPip = onCyclePbpPip
        self.onSwap = onSwap
    }

    /// Registers the hotkeys with the Carbon event system. Call once on launch.
    func register() {
        // (keyCode, modifiers) in registration order; dispatched by index.
        let spec: [(UInt32, UInt32)] = [
            (UInt32(kVK_ANSI_P), UInt32(cmdKey | shiftKey)),  // ⌘⇧P cycle
            (UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey)),  // ⌘⇧X swap
            (UInt32(kVK_ANSI_Q), UInt32(cmdKey)),             // ⌘Q quit
        ]

        // Install a single event handler that dispatches all our hotkeys.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        self.selfRef = selfPtr
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var eventID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventID
                )
                guard err == noErr else { return noErr }
                manager.handle(eventID: eventID.id)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard status == noErr else { return }

        for (index, entry) in spec.enumerated() {
            let id = EventHotKeyID(signature: OSType(0x41524F55), id: UInt32(index))  // "AROU"
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(
                entry.0, entry.1, id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if err == noErr, let ref {
                hotKeyRefs.append(ref)
            }
        }
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func handle(eventID: UInt32) {
        switch eventID {
        case 0: onCyclePbpPip()
        case 1: onSwap()
        case 2: NSApplication.shared.terminate(nil)
        default: break
        }
    }
}
