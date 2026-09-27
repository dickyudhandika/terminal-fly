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
}

/// Persists the panel frame whenever the user moves or resizes it.
final class PanelDelegate: NSObject, NSWindowDelegate {
    private let onFrameChange: (NSRect) -> Void
    private let onCustomFrame: () -> Void

    init(onFrameChange: @escaping (NSRect) -> Void, onCustomFrame: @escaping () -> Void) {
        self.onFrameChange = onFrameChange
        self.onCustomFrame = onCustomFrame
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onFrameChange(window.frame)
        onCustomFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onFrameChange(window.frame)
        onCustomFrame()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the panel hides it; the app (and shell) stays alive.
        sender.orderOut(nil)
        return false
    }
}
