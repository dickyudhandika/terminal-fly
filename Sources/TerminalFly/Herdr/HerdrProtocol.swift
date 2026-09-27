import Foundation

/// Wire protocol for herdr's socket API.
///
/// Kept free of socket I/O so framing, encoding, and decoding can be unit-tested
/// headlessly (`HerdrTests`). `HerdrClient` is the thin I/O shell around this.
///
/// Protocol as observed against herdr 0.8.2 (`herdr api schema --json`,
/// protocol 20, 91 methods):
///
///     request   {"id": "<correlation>", "method": "pane.list", "params": {}}\n
///     response  {"id": "...", "result": {...}}\n
///               {"id": "...", "error": {"code": "...", "message": "..."}}\n
///
/// Newline-delimited JSON on a Unix stream socket. Both the `id` field and the
/// trailing newline are mandatory: without `id` the server replies
/// `invalid_request: missing field 'id'`, and without the newline it waits
/// forever for the line terminator.
enum HerdrProtocol {
    /// Where herdr listens. The server socket drives panes; the client socket is
    /// the TUI's own.
    ///
    /// `HERDR_SOCKET` overrides the default, which matters two ways: herdr can be
    /// pointed at a non-standard config dir, and it is the only way to
    /// exercise the "herdr is not running" fallback in a test on a machine where
    /// herdr *is* running.
    static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["HERDR_SOCKET"], !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
    }

    // MARK: - Requests

    enum Method: String {
        case paneList = "pane.list"
        case paneRead = "pane.read"
        /// Raw bytes into the pane's input — what typing should use.
        case paneSendInput = "pane.send_input"
        /// Named keys ("Enter", "C-c") — for special keys.
        case paneSendKeys = "pane.send_keys"
        // Used only by the test harness to build and tear down an isolated
        // workspace; the app never creates workspaces.
        case workspaceCreate = "workspace.create"
        case workspaceClose = "workspace.close"
        case tabCreate = "tab.create"
        case eventsSubscribe = "events.subscribe"
        case ping
    }

    /// Serialises a request to its on-the-wire form, including the terminator.
    static func encode(id: String, method: Method, params: [String: Any] = [:]) throws -> Data {
        let object: [String: Any] = ["id": id, "method": method.rawValue, "params": params]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A) // newline terminator — required
        return data
    }

    /// Splits a receive buffer into complete newline-terminated frames, returning
    /// the leftover partial frame.
    ///
    /// The socket delivers arbitrary chunk boundaries, so a caller must buffer
    /// rather than assume one `read` equals one message.
    static func splitFrames(_ buffer: Data) -> (frames: [Data], remainder: Data) {
        var frames: [Data] = []
        var remainder = Data()
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            frames.append(Data(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        if start < buffer.endIndex {
            remainder = Data(buffer[start..<buffer.endIndex])
        }
        return (frames, remainder)
    }

    // MARK: - Responses

    enum Decoded {
        case result(id: String, value: Any)
        case failure(id: String, error: HerdrError)
        /// A server-pushed event (no request correlation of ours).
        case event(Any)
    }

    /// Decodes one frame. Throws only if the frame is not valid JSON at all —
    /// a server-reported error comes back as `.failure`, since that is a normal
    /// protocol outcome rather than a local decoding problem.
    static func decode(_ frame: Data) throws -> Decoded {
        let object = try JSONSerialization.jsonObject(with: frame)
        guard let dict = object as? [String: Any] else {
            throw HerdrError.malformed("frame is not a JSON object")
        }
        let id = dict["id"] as? String ?? ""
        if let errorDict = dict["error"] as? [String: Any] {
            return .failure(id: id, error: HerdrError.remote(
                code: errorDict["code"] as? String ?? "unknown",
                message: errorDict["message"] as? String ?? ""
            ))
        }
        if let result = dict["result"] {
            return .result(id: id, value: result)
        }
        return .event(object)
    }

    // MARK: - pane.list

    struct Pane: Equatable {
        var paneID: String
        var workspaceID: String?
        var tabID: String?
        var agent: String?
        var agentStatus: String?
        var cwd: String?
        var title: String?
        var focused: Bool

        /// One-line label for the session picker.
        var displayName: String {
            let title = (self.title?.isEmpty == false) ? self.title! : paneID
            return agent.map { "\(title) · \($0)" } ?? title
        }
    }

    /// Parses a `pane.list` result. Tolerant by design: herdr adds fields between
    /// versions, so unknown keys are ignored rather than rejected.
    static func decodePaneList(_ value: Any) throws -> [Pane] {
        guard let dict = value as? [String: Any],
              let rawPanes = dict["panes"] as? [[String: Any]] else {
            throw HerdrError.malformed("pane.list result missing 'panes'")
        }
        return rawPanes.compactMap { raw in
            guard let paneID = raw["pane_id"] as? String else { return nil }
            return Pane(
                paneID: paneID,
                workspaceID: raw["workspace_id"] as? String,
                tabID: raw["tab_id"] as? String,
                agent: raw["agent"] as? String,
                agentStatus: raw["agent_status"] as? String,
                cwd: raw["cwd"] as? String,
                title: raw["terminal_title_stripped"] as? String,
                focused: raw["focused"] as? Bool ?? false
            )
        }
    }

    /// Extracts the text of a `pane.read` result.
    static func decodePaneText(_ value: Any) throws -> String {
        guard let dict = value as? [String: Any],
              let read = dict["read"] as? [String: Any],
              let text = read["text"] as? String else {
            throw HerdrError.malformed("pane.read result missing 'read.text'")
        }
        return text
    }

    // MARK: - Params

    /// `pane.read` params.
    ///
    /// `source` must be one of visible / recent / recent_unwrapped / detection.
    /// Note `recent` returns *nothing* on a pane that has not scrolled out of its
    /// visible region — measured on a fresh pane. "visible" is what a viewer
    /// wants anyway: it is the current screen.
    static func readParams(paneID: String,
                           source: String = "visible",
                           lines: Int? = nil,
                           stripANSI: Bool = false,
                           format: String = "ansi") -> [String: Any] {
        var params: [String: Any] = [
            "pane_id": paneID,
            "source": source,
            "strip_ansi": stripANSI,
            "format": format,
        ]
        if let lines { params["lines"] = lines }
        return params
    }

    /// `pane.send_input` params — raw bytes into the pane. This is what typing
    /// uses; it does not submit, so a caller wanting a command run must send the
    /// newline separately.
    static func inputParams(paneID: String, text: String) -> [String: Any] {
        ["pane_id": paneID, "text": text]
    }

    /// `pane.send_keys` params — named keys such as "Enter" or "C-c".
    static func keysParams(paneID: String, keys: [String]) -> [String: Any] {
        ["pane_id": paneID, "keys": keys]
    }

    /// `events.subscribe` params for pane liveness.
    static func subscribeParams(_ eventTypes: [String]) -> [String: Any] {
        ["subscriptions": eventTypes.map { ["type": $0] }]
    }
}

/// Errors surfaced by the herdr layer.
enum HerdrError: Error, Equatable, CustomStringConvertible {
    /// The server answered with a protocol-level error.
    case remote(code: String, message: String)
    /// A reply we could not make sense of.
    case malformed(String)
    /// herdr is not running, or the socket is missing/unusable.
    case unavailable(String)

    var description: String {
        switch self {
        case let .remote(code, message): return "herdr error \(code): \(message)"
        case let .malformed(detail): return "malformed herdr reply: \(detail)"
        case let .unavailable(detail): return "herdr unavailable: \(detail)"
        }
    }

    /// True when falling back to the standalone shell is the right response —
    /// herdr simply is not there. Protocol errors mean herdr IS there and
    /// answered, which is a different situation worth surfacing to the user.
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
