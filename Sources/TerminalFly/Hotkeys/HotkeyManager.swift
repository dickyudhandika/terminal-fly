import AppKit
import Carbon.HIToolbox

/// A single global hotkey binding.
struct HotkeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Human-readable form for the settings UI ("⌃⌥P").
    var display: String

    static let defaultToggle = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥P"
    )

    static let defaultCycleCorner = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥C"
    )

    static let defaultHeightIncrease = HotkeyBinding(
        keyCode: UInt32(kVK_DownArrow),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥↓"
    )

    static let defaultHeightDecrease = HotkeyBinding(
        keyCode: UInt32(kVK_UpArrow),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥↑"
    )

    static let defaultWidthIncrease = HotkeyBinding(
        keyCode: UInt32(kVK_RightArrow),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥→"
    )

    static let defaultWidthDecrease = HotkeyBinding(
        keyCode: UInt32(kVK_LeftArrow),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥←"
    )
}

/// Registers system-wide hotkeys.
///
/// This uses the Carbon `RegisterEventHotKey` API, and that is deliberate —
/// SwiftUI's `.keyboardShortcut` and `NSEvent.addGlobalMonitorForEvents` cannot
/// register a real global hotkey:
///  - `.keyboardShortcut` only fires while the app is key, which it never is
///    (we are an accessory app with a non-activating panel).
///  - `addGlobalMonitorForEvents` observes but cannot consume, so the keystroke
///    still reaches whatever app is frontmost.
///
/// Carbon's hotkey API is ancient but is still the only supported way to do
/// this, and every shipping app that has global hotkeys uses it.
///
/// Threading: Carbon registers hotkeys against `GetEventDispatcherTarget()` and
/// dispatches them on the main thread's event loop. `@MainActor` on this class
/// therefore matches reality; the C callback hops in via
/// `MainActor.assumeIsolated` rather than a `Task` hop, which would add a
/// runloop turn of latency to every keypress.
@MainActor
final class HotkeyManager {
    private struct Registration {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Maps an action name to the binding currently registered for it, so we can
    /// unregister before re-registering when the user records a new combo.
    private var bindingsByAction: [String: (binding: HotkeyBinding, id: UInt32)] = [:]

    init() {
        installEventHandler()
    }

    /// Registers (or re-registers) a hotkey for a named action.
    /// - Returns: `nil` on success, or a human-readable error.
    @discardableResult
    func register(action: String, binding: HotkeyBinding,
                  handler: @escaping @MainActor () -> Void) -> String? {
        unregister(action: action)

        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        DebugLog.write("RegisterEventHotKey action=\(action) key=\(binding.keyCode) mods=\(binding.modifiers) status=\(status) resultRef=\(hotKeyRef != nil)")
        guard status == noErr, let ref = hotKeyRef else {
            // eventHotKeyExistsErr (-9878) is the conflict case: another app
            // (or the system) already owns that combo. Plan Risk 4.
            return Self.describe(status: status)
        }

        registrations[id] = Registration(ref: ref, handler: handler)
        bindingsByAction[action] = (binding, id)
        return nil
    }

    func unregister(action: String) {
        guard let existing = bindingsByAction.removeValue(forKey: action) else { return }
        if let registration = registrations.removeValue(forKey: existing.id) {
            UnregisterEventHotKey(registration.ref)
        }
    }

    func currentBinding(for action: String) -> HotkeyBinding? {
        bindingsByAction[action]?.binding
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        bindingsByAction.removeAll()
    }

    // MARK: - Carbon plumbing

    private static let signature: OSType = {
        // 'TFLY' as a four-char code.
        let chars: [UInt8] = [0x54, 0x46, 0x4C, 0x59]
        return chars.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event: event)
            },
            1,
            &spec,
            context,
            &handlerRef
        )
        eventHandler = handlerRef
    }

    /// Called from a C function pointer, so it has no actor context. Carbon
    /// delivers hotkeys on the main thread, which makes the `assumeIsolated`
    /// below honest rather than a guess.
    private nonisolated func handle(event: EventRef) -> OSStatus {
        // `EventRef` is a non-Sendable CF type; the closure captures it by
        // reference on the same thread, which Swift 6 cannot prove. Carbon
        // delivers hotkeys on the main thread, so this is safe.
        nonisolated(unsafe) let event = event
        return MainActor.assumeIsolated {
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == Self.signature else {
                return OSStatus(eventNotHandledErr)
            }
            guard let registration = registrations[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            registration.handler()
            return noErr
        }
    }

    private static func describe(status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr):
            return "That shortcut is already used by another app or by macOS. Pick a different combination."
        case OSStatus(paramErr):
            return "Invalid key combination (unsupported key code or modifier flags)."
        default:
            return "Could not register hotkey (Carbon status \(status))."
        }
    }
}

// MARK: - Key code → display string

enum HotkeyDisplay {
    /// Turns an AppKit key event into a "⌃⌥P"-style label.
    static func string(for event: NSEvent) -> String {
        var out = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        out += keyName(for: UInt32(event.keyCode))
        return out
    }

    /// Carbon modifier mask from an AppKit event, for `RegisterEventHotKey`.
    static func carbonModifiers(for event: NSEvent) -> UInt32 {
        var mask: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    static func keyName(for keyCode: UInt32) -> String {
        let specials: [Int: String] = [
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let special = specials[Int(keyCode)] { return special }
        return letterName(for: keyCode) ?? "Key \(keyCode)"
    }

    /// Reverse of `kVK_ANSI_*` for the keys a user is likely to bind.
    private static func letterName(for keyCode: UInt32) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Grave: "`",
        ]
        return map[Int(keyCode)]
    }
}
