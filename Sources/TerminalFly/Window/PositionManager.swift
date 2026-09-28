import AppKit

/// Owns the panel's position: corner presets, save/restore, and re-parking when
/// displays change.
///
/// All the arithmetic lives in `PanelGeometry` (pure, unit-tested); this class
/// is the AppKit shell around it — it supplies real `NSScreen.visibleFrame`
/// values and applies results to the real `NSPanel`.
///
/// Two things this has to get right, both learned painfully in the kitty +
/// Hammerspoon prototype:
///  1. A saved frame can end up on a display that no longer exists (external
///     monitor unplugged). Restoring it blindly puts the panel off-screen and it
///     looks like the app is broken. We validate against live screens and
///     re-park on the primary display instead.
///  2. Moving between displays must re-park, not just clamp — the panel should
///     end up at a *corner* of the right screen, not floating in the middle.
///     `NSWindow.didChangeScreenNotification` gives us that hook for free,
///     which is the simpler equivalent of kitty's `windowsChanged` re-parking.
@MainActor
final class PositionManager {
    private enum Key {
        static let frame = "panelFrame"
        static let corner = "panelCorner"
        /// Set when the user drags the panel manually; suppresses the corner
        /// preset until they pick a corner again.
        static let usesCustomFrame = "panelUsesCustomFrame"
    }

    private weak var panel: NSPanel?

    /// True while we are moving the panel ourselves. `windowDidMove` fires for
    /// programmatic `setFrame` calls too, so without this the delegate would
    /// mark every corner preset as a "custom" position and the presets would
    /// stop sticking.
    private(set) var isProgrammaticMove = false

    /// `nonisolated(unsafe)` so `deinit` can remove the observer. PositionManager
    /// lives for the whole app lifetime, so there is no real concurrency window
    /// here — the annotation just keeps Swift 6's deinit rules satisfied.
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    /// Wraps `setFrame` so the delegate can tell our moves from the user's.
    private func applyFrame(_ frame: NSRect, display: Bool) {
        guard let panel else { return }
        isProgrammaticMove = true
        panel.setFrame(frame, display: display, animate: false)
        // AppKit delivers the move notification during setFrame; clear the flag
        // on the next runloop tick so any coalesced notification still sees it.
        DispatchQueue.main.async { [weak self] in self?.isProgrammaticMove = false }
    }

    /// Applies a frame to the panel with the same programmatic-move guard as
    /// `applyFrame`, for callers outside this type (the fullscreen and
    /// small-screen presets in `PanelController`).
    func applyFrameExternal(_ frame: NSRect) {
        applyFrame(frame, display: true)
    }

    init(panel: NSPanel) {
        self.panel = panel
        updateSizeLimits()
        // Re-park when the panel lands on a different display.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reparkAfterScreenChange()
                // The new display has a different visible frame, so the drag
                // constraint has to follow the panel.
                self?.updateSizeLimits()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Corner presets

    var usesCustomFrame: Bool {
        get { UserDefaults.standard.bool(forKey: Key.usesCustomFrame) }
        set { UserDefaults.standard.set(newValue, forKey: Key.usesCustomFrame) }
    }

    var lastCorner: PanelCorner {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.corner),
                  let corner = PanelCorner(rawValue: raw) else { return .bottomRight }
            return corner
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.corner) }
    }

    func move(to corner: PanelCorner, on screen: NSScreen? = nil) {
        guard let panel else { return }
        guard let target = screen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        lastCorner = corner
        usesCustomFrame = false
        // A panel saved on a bigger display must come back at a size this one
        // can actually show, otherwise the preset itself overflows the screen.
        let size = PanelGeometry.clamped(panel.frame, in: target.visibleFrame).size
        let frame = PanelGeometry.frame(for: corner,
                                        size: size,
                                        in: target.visibleFrame)
        applyFrame(frame, display: true)
        updateSizeLimits()
        save()
    }

    /// Cycle through the four corners in a predictable order.
    @discardableResult
    func cycleCorner() -> PanelCorner {
        let next = lastCorner.next
        move(to: next)
        return next
    }

    // MARK: - Size

    /// AppKit enforces these during a mouse-drag resize, which is the only
    /// thing that stops a drag from running the panel off the display.
    ///
    /// Called at launch, after a corner preset moves the panel, and whenever it
    /// changes screen — a smaller display needs a smaller ceiling.
    func updateSizeLimits() {
        guard let panel else { return }
        // No screen at all (headless run, or a panel AppKit has not placed yet):
        // leave AppKit's unconstrained default alone rather than invent a
        // display size, which would shrink the panel to a fiction.
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.maxSize = PanelGeometry.maximumSize(in: visible)
        panel.minSize = CGSize(width: PanelGeometry.minimumWidth,
                               height: PanelGeometry.minimumHeight)
    }

    func adjustHeight(by delta: CGFloat) {
        guard let panel else { return }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = PanelGeometry.resized(panel.frame, byHeightDelta: delta, in: visible)
        applyFrame(frame, display: true)
        // A manual height change is a custom position even if the panel is still
        // parked in a corner — the user picked this size deliberately.
        usesCustomFrame = true
        save()
    }

    func adjustWidth(by delta: CGFloat) {
        guard let panel else { return }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = PanelGeometry.resizedWidth(panel.frame, byWidthDelta: delta, in: visible)
        applyFrame(frame, display: true)
        usesCustomFrame = true
        save()
    }

    // MARK: - Persistence

    func save() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Key.frame)
    }

    func markCustomFrame() {
        usesCustomFrame = true
        save()
    }

    /// Restore at launch. Falls back to the last corner preset (default
    /// bottom-right) when there is nothing usable saved.
    func restore() {
        guard panel != nil else { return }

        if let saved = savedFrame(), let screen = screen(for: saved),
           PanelGeometry.isUsable(saved, in: screen.visibleFrame) {
            // A custom frame is honoured as-is (the user put it there). A
            // corner-preset frame has to still look like a corner, otherwise a
            // resize on another display would leave it stranded mid-screen.
            if usesCustomFrame || PanelGeometry.isCornerLike(saved, in: screen.visibleFrame) {
                // Clamp first: a frame saved on a bigger display must not come
                // back hanging off this one.
                applyFrame(PanelGeometry.clamped(saved, in: screen.visibleFrame),
                           display: false)
                updateSizeLimits()
                return
            }
        }
        move(to: lastCorner)
    }

    private func savedFrame() -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: Key.frame) else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 40 && rect.height > 40 ? rect : nil
    }

    /// The live screen a saved frame belongs to, if any. A nil result means the
    /// frame refers to a display that is gone.
    private func screen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { PanelGeometry.isUsable(frame, in: $0.visibleFrame) }
            ?? NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
    }

    /// The display the panel was on went away, or it just moved: if it is not
    /// fully visible any more, re-park it at the last known corner of the
    /// primary screen.
    private func reparkAfterScreenChange() {
        guard let panel else { return }
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }
        if !PanelGeometry.isFullyVisible(panel.frame, in: visible) {
            move(to: lastCorner, on: NSScreen.main)
        }
    }
}
