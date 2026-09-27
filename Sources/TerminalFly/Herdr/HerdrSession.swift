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
final class HerdrSession {
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

    private(set) var state: State = .disconnected(reason: "not started")
    private(set) var panes: [HerdrProtocol.Pane] = []
    private(set) var followedPaneID: String?

    /// Last screen text we handed out — the redraw suppression.
    private var lastScreen: String?

    /// Delivered (on the main queue) whenever the pane's visible contents change.
    var onScreenChange: ((String) -> Void)?
    /// Delivered (on the main queue) when the pane list changes.
    var onPanesChange: (([HerdrProtocol.Pane]) -> Void)?
    /// Delivered (on the main queue) on connect/disconnect.
    var onStateChange: ((State) -> Void)?

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
        let value = try transport.call(.paneList, params: [:])
        let decoded = try HerdrProtocol.decodePaneList(value)
        if decoded != panes {
            panes = decoded
            onPanesChange?(decoded)
        }
        return decoded
    }

    /// The pane herdr itself has focused — the natural default when the user has
    /// not picked one.
    var focusedPane: HerdrProtocol.Pane? {
        panes.first(where: { $0.focused }) ?? panes.first
    }

    /// Begins following a pane. Resets the redraw cache so the first poll always
    /// paints, even if the screen happens to match a previous pane's text.
    func follow(paneID: String) {
        followedPaneID = paneID
        lastScreen = nil
        update(.connected(paneID: paneID))
    }

    func unfollow() {
        followedPaneID = nil
        lastScreen = nil
    }

    // MARK: - Polling

    /// Reads the followed pane once. Returns the screen text when it changed
    /// since the last poll, `nil` when nothing changed (or nothing is followed).
    ///
    /// Called directly by tests; `startPolling` drives it on a timer in the app.
    @discardableResult
    func pollOnce() throws -> String? {
        guard let paneID = followedPaneID else { return nil }

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

    // MARK: - Input

    /// Sends literal text (no newline). herdr appends it to the pane's input.
    func sendText(_ text: String) throws {
        guard let paneID = followedPaneID else { return }
        _ = try transport.call(.paneSendInput, params: HerdrProtocol.inputParams(
            paneID: paneID, text: text
        ))
        // Our own input changes the screen; clear the cache so the next poll
        // repaints immediately instead of waiting for a difference.
        lastScreen = nil
    }

    /// Sends named keys, e.g. `["Enter"]`, `["C-c"]`.
    func sendKeys(_ keys: [String]) throws {
        guard let paneID = followedPaneID else { return }
        _ = try transport.call(.paneSendKeys, params: HerdrProtocol.keysParams(
            paneID: paneID, keys: keys
        ))
        lastScreen = nil
    }

    // MARK: - Lifecycle

    /// Records a transport failure. Only a genuinely dead herdr leaves herdr
    /// mode; a protocol-level error keeps the connection and surfaces the error.
    func handleFailure(_ error: Error) {
        guard let herdrError = error as? HerdrError, herdrError.isUnavailable else { return }
        unfollow()
        update(.disconnected(reason: herdrError.description))
    }

    func markDisconnected(reason: String) {
        unfollow()
        update(.disconnected(reason: reason))
    }

    private func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
