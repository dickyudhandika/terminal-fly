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
