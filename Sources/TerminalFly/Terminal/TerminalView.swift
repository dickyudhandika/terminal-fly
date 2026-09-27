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
