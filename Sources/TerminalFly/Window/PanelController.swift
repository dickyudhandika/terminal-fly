import AppKit

/// Owns the single floating panel.
///
/// The core product insight: because Terminal Fly owns this window, we can set
/// `NSWindow.level = .floating` directly. No Hammerspoon, no AX API, no socket
/// poking at a foreign app's window (macOS has no public API to set another
/// app's window level — that sandbox boundary is exactly why the previous
/// kitty + Hammerspoon setup needed so much machinery).
///
/// Focus model (Option A): the panel uses `.nonactivatingPanel` so clicking it
/// does NOT activate Terminal Fly — the underlying app (Figma, editor) stays
/// frontmost and keeps its menu bar. Because `canBecomeKey` returns `true`, the
/// panel still accepts keyboard input when clicked, so typing works without a
/// mode switch. Clicking any other app hands focus straight back.
@MainActor
final class PanelController {
    let panel: TerminalFlyPanel
    private let windowDelegate: PanelDelegate
    let surface: TerminalSurface
    let positions: PositionManager

    /// herdr display surface, created lazily — a user with no herdr should never
    /// pay for it, and its existence is the signal that herdr mode is active.
    private(set) var herdrSurface: HerdrDisplaySurface?

    /// Which view currently fills the panel.
    private var contentView = NSView()

    /// The window's corner radius, in points.
    ///
    /// Sharper than the macOS default (18pt for this style mask as of
    /// macOS 26), which suits a terminal overlay better than the stock look.
    static let cornerRadius: CGFloat = 8

    init(configuration: ShellConfiguration = .default()) {
        let defaultFrame = NSRect(x: 0, y: 0, width: 620, height: 320)

        panel = TerminalFlyPanel(
            contentRect: defaultFrame,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable,
                        .miniaturizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        positions = PositionManager(panel: panel)
        windowDelegate = PanelDelegate(
            onFrameChange: { [weak panel] frame in
                guard let panel, panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromRect(frame), forKey: "panelFrame")
            },
            onCustomFrame: { [weak positions] in
                guard let positions, !positions.isProgrammaticMove else { return }
                positions.markCustomFrame()
            },
            clampFrame: { [weak panel] frame in
                guard let panel,
                      let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return frame }
                return PanelGeometry.clamped(frame, in: visible)
            }
        )
        panel.delegate = windowDelegate

        // Float above every other app, on every Space.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Floating-panel behaviour: never hides when the app deactivates.
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        // Accept keyboard input on click without activating the app.
        panel.becomesKeyOnlyIfNeeded = false

        // Drag the panel by any empty area of its background.
        panel.isMovableByWindowBackground = true

        // Semi-transparent by design (opacity becomes configurable in Step 5).
        panel.alphaValue = 0.92
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false

        // Content: the SwiftTerm surface, pinning its own edges.
        surface = TerminalSurface(frame: defaultFrame, configuration: configuration)
        showStandalone()
        applyCornerRadius()

        positions.restore()
    }

    // MARK: - Mode switching

    /// Standalone mode: the local PTY surface fills the panel.
    func showStandalone() {
        install(surface)
    }

    /// herdr mode: replace the PTY surface with the herdr display.
    ///
    /// The PTY surface is *kept*, not destroyed: if herdr dies mid-session the app
    /// falls back to a working shell rather than an empty panel.
    @discardableResult
    func showHerdr() -> HerdrDisplaySurface {
        let display: HerdrDisplaySurface
        if let existing = herdrSurface {
            display = existing
        } else {
            display = HerdrDisplaySurface(frame: panel.contentView?.bounds ?? .zero)
            herdrSurface = display
        }
        install(display)
        return display
    }

    var isHerdrMode: Bool {
        guard let herdrSurface else { return false }
        return herdrSurface.superview != nil
    }

    private func install(_ view: NSView) {
        if !contentView.subviews.isEmpty {
            for subview in contentView.subviews { subview.removeFromSuperview() }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)

        // Pin to the safe-area guide, not the content view's own edges.
        //
        // `.fullSizeContentView` + `titlebarAppearsTransparent` make
        // `contentView` span the whole window, title bar included, so its top
        // edge sits *under* the traffic-light buttons. The safe-area guide is
        // inset by the title bar height (24pt here), which is what keeps the
        // first line or two of shell output from being swallowed by the buttons.
        let guide = contentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            view.topAnchor.constraint(equalTo: guide.topAnchor),
            view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        panel.contentView = contentView
    }

    // MARK: - Appearance

    /// Applies `Self.cornerRadius` to the window.
    ///
    /// This is the one place the app reaches for a private AppKit selector, and
    /// it is not a preference: AppKit has no public API for a window's corner
    /// radius. The public alternatives were measured, not guessed, and both fail:
    ///
    ///  * `contentView.layer.cornerRadius` — the content view sits *inside* the
    ///    window frame, which AppKit draws and masks itself, and the frame's
    ///    radius wins. A window set to 20pt this way still screenshots as 18pt.
    ///  * `contentView.superview.layer.cornerRadius` (the theme frame) — this
    ///    does alter the silhouette, but only as a layer mask. macOS 26 gives
    ///    the theme frame a glass edge whose highlight is drawn outside that
    ///    mask, so the mask shaves the frame without producing a clean corner.
    ///  * `NSViewCornerConfiguration` — the supported-looking modern API, but it
    ///    is not on `NSThemeFrame` in this SDK, so Swift cannot call it here.
    ///
    /// `NSWindow._setCornerRadius:` is `-setCornerRadius:` taking a `double`. It
    /// drives the same `_cornerPath` / `_cornerMask` the real corner uses, and
    /// was measured to render an exact 8pt silhouette, to survive resize and
    /// hide/show, and to leave a matching — not stale — shadow.
    ///
    /// The lookup is guarded so a future macOS that drops the selector leaves
    /// the panel with its system corner instead of crashing.
    private func applyCornerRadius() {
        let selector = Selector(("_setCornerRadius:"))
        guard panel.responds(to: selector) else { return }
        panel.perform(selector, with: Self.cornerRadius)
        // The shadow path is derived from the corner radius; without this the
        // old, larger path lingers until something else invalidates it.
        panel.invalidateShadow()
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: - Position

    /// Cycle through the corner presets (⌃⌥C). Returns the new corner so the
    /// caller can surface it in the menu bar / HUD later.
    @discardableResult
    func cycleCorner() -> PanelCorner {
        positions.cycleCorner()
    }

    func grow() {
        positions.adjustHeight(by: PanelGeometry.resizeStep)
    }

    func shrink() {
        positions.adjustHeight(by: -PanelGeometry.resizeStep)
    }

    func growWidth() {
        positions.adjustWidth(by: PanelGeometry.resizeStep)
    }

    func shrinkWidth() {
        positions.adjustWidth(by: -PanelGeometry.resizeStep)
    }

    func setOpacity(_ value: CGFloat) {
        panel.alphaValue = max(0.2, min(1.0, value))
    }

    var opacity: CGFloat { panel.alphaValue }

    /// Opacity levels the ⌃⌥O hotkey cycles through, ascending. `nonisolated` so
    /// the pure-logic test target and the menu can read it without the main actor.
    nonisolated static let opacityPresets: [CGFloat] = [0.3, 0.5, 0.7, 0.85, 1.0]

    /// Cycles panel opacity through the presets, wrapping at the top. Returns the
    /// value it applied so the caller can keep the stored preference in sync.
    ///
    /// Stateless on purpose: the next level is derived from whatever alpha the
    /// panel actually has right now. The Appearance slider and the
    /// transparent-when-unfocused rule both write alpha behind this method's
    /// back, and a remembered index would then resume from a level that no
    /// longer matches what the user is looking at.
    @discardableResult
    func cycleOpacity() -> CGFloat {
        let current = panel.alphaValue
        // A hair of tolerance so a preset we just applied counts as "current"
        // and the cycle advances instead of sticking on it.
        let next = Self.opacityPresets.first { $0 > current + 0.001 }
            ?? Self.opacityPresets[0]
        setOpacity(next)
        return next
    }

    // MARK: - Fullscreen / small screen toggles

    /// Frame to restore when leaving fullscreen or small screen.
    private var savedFrame: NSRect?

    /// Whether the panel is currently showing the fullscreen preset.
    private(set) var isFullscreen = false

    /// Whether the panel is currently showing the small-screen preset.
    private(set) var isSmallScreen = false

    /// Toggles the panel between the fullscreen preset and its previous frame.
    ///
    /// The two presets share one saved frame, so a fullscreen → small screen →
    /// fullscreen chain still comes back to the frame the user actually had,
    /// rather than to whatever the other preset last applied.
    func toggleFullscreen() {
        if isFullscreen {
            restoreSavedFrame()
            return
        }
        // Entering from the *other* preset must keep the frame saved when that
        // one was entered — `panel.frame` here is the preset, not the user's.
        let original = isSmallScreen ? (savedFrame ?? panel.frame) : panel.frame
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        savedFrame = original
        isSmallScreen = false
        positions.applyFrameExternal(PanelGeometry.fullscreenFrame(in: visible))
        isFullscreen = true
    }

    /// Toggles the panel between the small-screen preset and its previous frame.
    func toggleSmallScreen() {
        if isSmallScreen {
            restoreSavedFrame()
            return
        }
        let original = isFullscreen ? (savedFrame ?? panel.frame) : panel.frame
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        savedFrame = original
        isFullscreen = false
        positions.applyFrameExternal(PanelGeometry.smallFrame(in: visible))
        isSmallScreen = true
    }

    /// Leaves whichever preset is active and puts the user's frame back.
    private func restoreSavedFrame() {
        if let saved = savedFrame {
            positions.applyFrameExternal(saved)
        }
        savedFrame = nil
        isFullscreen = false
        isSmallScreen = false
    }

    func saveFrame() {
        positions.save()
    }
}
