import AppKit
import SwiftTerm

/// The panel's terminal surface.
///
/// A thin subclass (rather than a bare `LocalProcessTerminalView`) so we can:
///  - own the shell configuration and delegate wiring in one place
///  - apply appearance (font, colours) imperatively from `PreferencesStore`
///  - expose `restartShell()` for the menu bar
///
/// Note on transparency: `isOpaque = false` on the panel lets the window's
/// `alphaValue` show through, but SwiftTerm paints its own background colour.
/// We set `nativeBackgroundColor` to the panel's colour so the two compose
/// instead of fighting.
final class TerminalSurface: LocalProcessTerminalView {
    private var configuration: ShellConfiguration

    /// Named `hostDelegate`, not `terminalDelegate` — the latter is an existing
    /// SwiftTerm property (`TerminalViewDelegate`) and would collide.
    let hostDelegate = TerminalDelegate()

    init(frame: CGRect, configuration: ShellConfiguration = .default()) {
        self.configuration = configuration
        super.init(frame: frame)
        wantsLayer = true
        processDelegate = hostDelegate
        startShell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the panel builds its view in code")
    }

    // MARK: - Window-drag vs. terminal-click arbitration

    /// AppKit asks this during the left-mouse-down hit-test to decide whether
    /// the click starts a window drag (`panel.isMovableByWindowBackground =
    /// true`). The default `NSView` answer is `true`, which hands the press to
    /// the panel's drag machinery — SwiftTerm's `mouseDown`/`mouseDragged`/
    /// `mouseUp` never run, so click-drag selection is dead.
    ///
    /// Returning `false` gives the click to this view instead. It only affects
    /// clicks that land inside the surface's frame; the title bar sits outside
    /// it (the surface is pinned to `contentView.safeAreaLayoutGuide`, one
    /// title bar below the top), so dragging by the title bar still moves the
    /// panel. Note the surface fills the panel edge to edge below that bar, so
    /// this does make the terminal body select-only, not drag-by-background.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    // MARK: - Select-to-copy

    /// Copy a finished drag-selection to the general pasteboard — the
    /// "highlight text, get it copied" behaviour.
    ///
    /// `super` runs first: it finalises the drag selection and handles link
    /// clicks, mouse reporting, and semantic-prompt routing. `copy(_:)` then
    /// uses SwiftTerm's own path (`selection.getSelectedText()` →
    /// `NSPasteboard.general`), the same one the Edit menu and OSC 52 use.
    ///
    /// The guard matters: a bare click clears `selection.active` in
    /// `mouseDown`, so a click that merely dismisses a selection copies
    /// nothing, while a drag (or double/triple click) leaves it set.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if selection.active, selection.hasSelectionRange {
            copy(self)
        }
    }

    // MARK: - Appearance

    func applyFont(_ font: NSFont) {
        self.font = font
    }

    func applyColors(background: NSColor, foreground: NSColor,
                     caret: NSColor, selection: NSColor) {
        nativeBackgroundColor = background
        nativeForegroundColor = foreground
        caretColor = caret
        selectedTextBackgroundColor = selection
    }

    // MARK: - Shell lifecycle

    func applyConfiguration(_ configuration: ShellConfiguration) {
        self.configuration = configuration
    }

    func startShell() {
        startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment(),
            execName: "-" + (configuration.executable as NSString).lastPathComponent,
            currentDirectory: configuration.workingDirectory
        )
    }

    /// Shut the shell down and spawn a fresh one (menu bar → "New Shell").
    func restartShell() {
        if process.running { process.terminate() }
        startShell()
    }
}
