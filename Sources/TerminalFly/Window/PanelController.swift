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
        surface.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content

        positions.restore()
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
        positions.adjustHeight(by: 24)
    }

    func shrink() {
        positions.adjustHeight(by: -24)
    }

    func setOpacity(_ value: CGFloat) {
        panel.alphaValue = max(0.2, min(1.0, value))
    }

    var opacity: CGFloat { panel.alphaValue }

    func saveFrame() {
        positions.save()
    }
}
