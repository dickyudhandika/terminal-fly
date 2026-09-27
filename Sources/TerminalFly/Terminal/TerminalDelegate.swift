import AppKit
import SwiftTerm

/// SwiftTerm delegate for the panel's terminal.
///
/// `LocalProcessTerminalView` is its own `TerminalViewDelegate` and reposts the
/// host-relevant callbacks through `LocalProcessTerminalViewDelegate`. We
/// implement that protocol rather than `TerminalViewDelegate` directly —
/// overriding SwiftTerm's own delegate would break its internal wiring.
final class TerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    /// Called on shell exit. Standalone mode currently just reports it; a
    /// "restart shell" affordance arrives with the menu bar (Step 6).
    var onProcessTerminated: ((Int32?) -> Void)?

    /// Called when the terminal title changes (shells emit OSC 0/2).
    var onTitleChange: ((String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Nothing to do: the PTY is resized by SwiftTerm via
        // `process.updateWindowSize` inside its own implementation. The panel
        // stays user-resizable (unlike kitty's locked overlay).
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Reserved for profiles / working-directory restore (P2).
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onProcessTerminated?(exitCode)
    }
}
