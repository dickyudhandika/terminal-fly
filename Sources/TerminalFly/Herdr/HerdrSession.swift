import Foundation

/// Lets `HerdrSession` be driven by a fake in tests.
///
/// Exists because the session's real job — deciding *when* to redraw, what to do
/// when a pane vanishes, and how to keep polling cheap — is worth testing
/// without a herdr process, a socket, or a window server.
protocol HerdrTransport {
    func call(_ method: HerdrProtocol.Method, params: [String: Any]) throws -> Any
}

extension HerdrClient: HerdrTransport {}

/// Drives a herdr pane for display in the floating panel.
///
/// ## Why polling, and not events
///
/// Measured against herdr 0.8.2: the 27 subscribable event types are all
/// *metadata* (`pane.updated` fires when a pane's title, cwd, focus or agent
/// status changes). None of them carries pane output, and `pane.updated` does
/// not fire merely because a pane printed something — verified by generating
/// output in an idle pane and observing zero events.
///
/// So the bridge polls `pane.read(source: "visible")` and repaints only when the
/// text actually changes. `minimumPollInterval` is therefore a latency knob, not
/// a correctness one.
///
/// ## Thread safety
///
/// Every access to mutable state goes through the serial `queue`, which is what
/// justifies `@unchecked Sendable`. That matters because polling runs on a
/// background timer while typing arrives on the main thread: without
/// serialization a poll and a keystroke race on `lastScreen`, and two slow polls
/// can overlap and both repaint.
///
/// Callbacks (`onScreenChange` etc.) fire *from inside* the queue, so callers
/// must hop to the main queue themselves — the coordinator does. Never call back
/// into the session synchronously from a callback; that would deadlock on the
/// non-reentrant serial queue.
final class HerdrSession: @unchecked Sendable {
    /// What the panel should be showing right now.
    enum State: Equatable {
        case connected(paneID: String)
        /// herdr is gone. The panel must leave herdr mode rather than freeze.
        case disconnected(reason: String)
    }

    private let transport: HerdrTransport

    /// Interval between polls while following a pane. 400 ms is under the
    /// threshold where typing feels disconnected, and a local socket read is
    /// cheap enough that it is not worth being cleverer.
    let minimumPollInterval: TimeInterval = 0.4

    /// Serializes all mutable state below. See "Thread safety" above.
    private let queue = DispatchQueue(label: "terminalfly.herdr.session")

    private var _state: State = .disconnected(reason: "not started")
    private var _panes: [HerdrProtocol.Pane] = []
    private var _followedPaneID: String?

    /// Last screen text we handed out — the redraw suppression.
    private var lastScreen: String?

    /// Delivered (from inside the queue) whenever the pane's visible contents
    /// change. Hop to the main queue before touching UI.
    var onScreenChange: ((String) -> Void)?
    /// Delivered (from inside the queue) when the pane list changes.
    var onPanesChange: (([HerdrProtocol.Pane]) -> Void)?
    /// Delivered (from inside the queue) on connect/disconnect.
    var onStateChange: ((State) -> Void)?

    // MARK: - Read-only views

    var state: State { queue.sync { _state } }
    var panes: [HerdrProtocol.Pane] { queue.sync { _panes } }
    var followedPaneID: String? { queue.sync { _followedPaneID } }

    init(transport: HerdrTransport) {
        self.transport = transport
    }

    convenience init() {
        self.init(transport: HerdrClient())
    }

    // MARK: - Panes

    /// Refreshes the pane list. Throws when herdr is unreachable so the caller
    /// can decide between falling back and showing an error.
    @discardableResult
    func refreshPanes() throws -> [HerdrProtocol.Pane] {
        try queue.sync {
            let value = try transport.call(.paneList, params: [:])
            let decoded = try HerdrProtocol.decodePaneList(value)
            if decoded != _panes {
                _panes = decoded
                onPanesChange?(decoded)
            }
            return decoded
        }
    }

    /// The pane herdr itself has focused — the natural default when the user has
    /// not picked one.
    var focusedPane: HerdrProtocol.Pane? {
        queue.sync { _panes.first(where: { $0.focused }) ?? _panes.first }
    }

    /// Begins following a pane. Resets the redraw cache so the first poll always
    /// paints, even if the screen happens to match a previous pane's text.
    func follow(paneID: String) {
        queue.sync {
            _followedPaneID = paneID
            lastScreen = nil
            update(.connected(paneID: paneID))
        }
    }

    func unfollow() {
        queue.sync {
            _followedPaneID = nil
            lastScreen = nil
        }
    }

    // MARK: - Polling

    /// Reads the followed pane once. Returns the screen text when it changed
    /// since the last poll, `nil` when nothing changed (or nothing is followed).
    ///
    /// Called directly by tests; the app drives it from a timer.
    @discardableResult
    func pollOnce() throws -> String? {
        try queue.sync {
            guard let paneID = _followedPaneID else { return nil }

            let value = try transport.call(.paneRead, params: HerdrProtocol.readParams(
                paneID: paneID,
                source: "visible",
                stripANSI: false,
                format: "ansi"
            ))
            let text = try HerdrProtocol.decodePaneText(value)

            guard text != lastScreen else { return nil }
            lastScreen = text
            onScreenChange?(text)
            return text
        }
    }

    // MARK: - Input

    /// Sends literal text to the pane's PTY. herdr writes it to stdin, so
    /// `\r` and `\n` are interpreted by the shell — same as a real terminal.
    func sendText(_ text: String) throws {
        try queue.sync {
            guard let paneID = _followedPaneID else { return }
            _ = try transport.call(.paneSendText, params: HerdrProtocol.textParams(
                paneID: paneID, text: text
            ))
            // Our own input changes the screen; clear the cache so the next poll
            // repaints immediately instead of waiting for a difference.
            lastScreen = nil
        }
    }

    /// Sends named keys, e.g. `["Enter"]`, `["C-c"]`.
    func sendKeys(_ keys: [String]) throws {
        try queue.sync {
            guard let paneID = _followedPaneID else { return }
            _ = try transport.call(.paneSendKeys, params: HerdrProtocol.keysParams(
                paneID: paneID, keys: keys
            ))
            lastScreen = nil
        }
    }

    // MARK: - Lifecycle

    /// Records a transport failure. Only a genuinely dead herdr leaves herdr
    /// mode; a protocol-level error keeps the connection and surfaces the error.
    func handleFailure(_ error: Error) {
        queue.sync {
            guard let herdrError = error as? HerdrError, herdrError.isUnavailable else { return }
            _followedPaneID = nil
            lastScreen = nil
            update(.disconnected(reason: herdrError.description))
        }
    }

    func markDisconnected(reason: String) {
        queue.sync {
            _followedPaneID = nil
            lastScreen = nil
            update(.disconnected(reason: reason))
        }
    }

    /// Caller must already hold `queue`.
    private func update(_ newState: State) {
        guard newState != _state else { return }
        _state = newState
        onStateChange?(newState)
    }
}
