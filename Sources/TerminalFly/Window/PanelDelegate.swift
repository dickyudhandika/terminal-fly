import AppKit

/// `NSPanel` subclass that accepts keyboard input without activating the app.
///
/// `NSPanel` already refuses main-window status, which is what we want — the
/// panel is never the app's main window. `canBecomeKey` must be overridden to
/// `true` because the default for a `.nonactivatingPanel` is decided by AppKit
/// in ways that vary with `styleMask`; returning `true` explicitly is the
/// documented way to get "click to type, focus stays put elsewhere".
final class TerminalFlyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Routes the terminal-editing key equivalents AppKit would otherwise drop.
    ///
    /// The app is a menu-bar accessory (`.accessory` activation policy), so it
    /// has no main menu and therefore none of AppKit's standard Edit commands.
    /// Cmd+V is normally handled by the Edit > Paste menu item, whose key
    /// equivalent AppKit resolves from the menu bar and then targets at the
    /// first responder. With no menu, `NSApplication.sendEvent` finds nothing
    /// that handles the keystroke and discards it — SwiftTerm's `paste(_:)` is
    /// never called, even though the terminal view implements it.
    ///
    /// Intercepting here instead is the narrowest fix: it runs before the
    /// key-binding machinery, only for the terminal's own editing keys, and it
    /// hands the work back to a responder, so SwiftTerm's paste semantics
    /// (bracketed paste, kitty keyboard protocol) are unchanged.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.window === self,
              let selector = Self.terminalEditingSelector(for: event),
              let target = editingTarget(for: selector)
        else { return super.performKeyEquivalent(with: event) }

        _ = target.tryToPerform(selector, with: event)
        return true
    }

    /// The responder an editing command should go to.
    ///
    /// The first responder is preferred, but it is not always the terminal:
    /// clicking the title bar leaves the window as responder, and Cmd+V should
    /// still paste into the terminal the user is looking at. So the content
    /// hierarchy is searched as a fallback.
    private func editingTarget(for selector: Selector) -> NSResponder? {
        if let responder = firstResponder, responder.responds(to: selector) {
            return responder
        }
        var pending = contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if view.responds(to: selector) { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Maps a bare Cmd keystroke to the responder-chain selector it stands for.
    ///
    /// Cmd+C is deliberately absent: the terminal view's `copy(_:)` copies only
    /// its own selection, while every macOS app expects Cmd+C to reach the
    /// system Services menu.
    private static func terminalEditingSelector(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return nil }

        switch event.charactersIgnoringModifiers {
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSResponder.selectAll(_:))
        default: return nil
        }
    }
}

/// Persists the panel frame whenever the user moves or resizes it.
final class PanelDelegate: NSObject, NSWindowDelegate {
    private let onFrameChange: (NSRect) -> Void
    private let onCustomFrame: () -> Void
    /// Safety net for a resize that ended larger than the screen allows.
    /// AppKit already refuses to drag past `NSWindow.maxSize`, so this only
    /// fires when the ceiling moved under the panel (display change mid-drag).
    private let clampFrame: (NSRect) -> NSRect

    init(onFrameChange: @escaping (NSRect) -> Void,
         onCustomFrame: @escaping () -> Void,
         clampFrame: @escaping (NSRect) -> NSRect = { $0 }) {
        self.onFrameChange = onFrameChange
        self.onCustomFrame = onCustomFrame
        self.clampFrame = clampFrame
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onFrameChange(window.frame)
        onCustomFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let clamped = clampFrame(window.frame)
        if clamped != window.frame {
            window.setFrame(clamped, display: true, animate: false)
        }
        onFrameChange(clamped)
        onCustomFrame()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the panel hides it; the app (and shell) stays alive.
        sender.orderOut(nil)
        return false
    }
}
