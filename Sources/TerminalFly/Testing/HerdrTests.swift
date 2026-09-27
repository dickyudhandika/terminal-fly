import Foundation

/// Tests for the pure herdr protocol layer: framing, encoding, decoding.
///
/// These run headlessly (`--test`) with no socket and no herdr running, which is
/// the point — the wire format is the part worth pinning down, and it is exactly
/// the part that is painful to debug against a live server.
enum HerdrTests {
    static func run() {
        TestHarness.group("HerdrProtocol — request encoding") {
            let data = try! HerdrProtocol.encode(id: "r1", method: .paneList, params: [:])
            TestHarness.expect(data.last == 0x0A, "encoded request is newline-terminated")

            let text = String(data: data, encoding: .utf8) ?? ""
            TestHarness.expect(text.contains("\"id\":\"r1\""), "request carries the correlation id")
            TestHarness.expect(text.contains("\"method\":\"pane.list\""), "request carries the method")
            TestHarness.expect(text.contains("\"params\":{}"), "request carries params")
        }

        TestHarness.group("HerdrProtocol — framing") {
            // The socket delivers arbitrary chunk boundaries; a reader must not
            // assume one read == one message.
            let two = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
            let split = HerdrProtocol.splitFrames(two)
            TestHarness.expect(split.frames.count == 2, "two complete frames split out")
            TestHarness.expect(split.remainder.isEmpty, "no remainder for complete input")

            let partial = Data("{\"a\":1}\n{\"b\":".utf8)
            let split2 = HerdrProtocol.splitFrames(partial)
            TestHarness.expect(split2.frames.count == 1, "one complete frame, one partial")
            TestHarness.expect(String(data: split2.remainder, encoding: .utf8) == "{\"b\":",
                               "partial frame retained for the next read")

            let none = HerdrProtocol.splitFrames(Data("{\"half".utf8))
            TestHarness.expect(none.frames.isEmpty, "no frames without a newline")
            TestHarness.expect(none.remainder.count == 6, "whole input retained as remainder")

            let empty = HerdrProtocol.splitFrames(Data())
            TestHarness.expect(empty.frames.isEmpty && empty.remainder.isEmpty, "empty buffer is safe")
        }

        TestHarness.group("HerdrProtocol — response decoding") {
            let ok = try! HerdrProtocol.decode(Data("{\"id\":\"x\",\"result\":{\"ok\":true}}".utf8))
            if case let .result(id, _) = ok {
                TestHarness.expect(id == "x", "result keeps its correlation id")
            } else {
                TestHarness.expect(false, "result frame decoded as result")
            }

            // A server-reported error is a normal protocol outcome, not a local
            // decoding failure — it must not throw.
            let bad = try! HerdrProtocol.decode(
                Data("{\"id\":\"\",\"error\":{\"code\":\"invalid_request\",\"message\":\"missing field `id`\"}}".utf8))
            if case let .failure(_, error) = bad {
                TestHarness.expect(error == .remote(code: "invalid_request", message: "missing field `id`"),
                                   "error frame decoded with code and message")
            } else {
                TestHarness.expect(false, "error frame decoded as failure")
            }

            // Server-pushed events have no id of ours.
            let event = try! HerdrProtocol.decode(Data("{\"type\":\"pane.updated\"}".utf8))
            if case .event = event {
                TestHarness.expect(true, "id-less frame treated as an event")
            } else {
                TestHarness.expect(false, "id-less frame treated as an event")
            }

            var threw = false
            do { _ = try HerdrProtocol.decode(Data("not json".utf8)) } catch { threw = true }
            TestHarness.expect(threw, "non-JSON frame throws")
        }

        TestHarness.group("HerdrProtocol — pane.list decoding") {
            // Shaped after a real herdr 0.8.2 reply.
            let json = """
            {"panes":[
              {"pane_id":"w5:p17","workspace_id":"w5","tab_id":"w5:t1","agent":"hermes",
               "agent_status":"idle","cwd":"/tmp","focused":false,
               "terminal_title_stripped":"Plan session"},
              {"pane_id":"w7:p1","focused":true}
            ]}
            """
            let value = try! JSONSerialization.jsonObject(with: Data(json.utf8))
            let panes = try! HerdrProtocol.decodePaneList(value)
            TestHarness.expect(panes.count == 2, "both panes parsed")

            TestHarness.expect(panes[0].paneID == "w5:p17", "pane_id read")
            TestHarness.expect(panes[0].agent == "hermes", "agent read")
            TestHarness.expect(panes[0].agentStatus == "idle", "agent_status read")
            TestHarness.expect(panes[0].title == "Plan session", "title read")
            TestHarness.expect(panes[0].focused == false, "focused read")

            // Sparse entries must not crash or be dropped.
            TestHarness.expect(panes[1].paneID == "w7:p1", "sparse pane still parsed")
            TestHarness.expect(panes[1].agent == nil, "absent agent is nil")
            TestHarness.expect(panes[1].focused == true, "focused read on sparse pane")

            // displayName: title when present, pane id otherwise, agent appended.
            TestHarness.expect(panes[0].displayName == "Plan session · hermes",
                               "displayName joins title and agent")
            TestHarness.expect(panes[1].displayName == "w7:p1",
                               "displayName falls back to pane id")

            var threw = false
            do { _ = try HerdrProtocol.decodePaneList(["nope": 1]) } catch { threw = true }
            TestHarness.expect(threw, "malformed pane.list result throws")

            // Unknown future fields are ignored, not fatal.
            let future = try! JSONSerialization.jsonObject(
                with: Data("{\"panes\":[{\"pane_id\":\"a\",\"brand_new_field\":42}]}".utf8))
            let parsed = try! HerdrProtocol.decodePaneList(future)
            TestHarness.expect(parsed.count == 1, "unknown fields are ignored")
        }

        TestHarness.group("HerdrProtocol — pane.read decoding") {
            let value = try! JSONSerialization.jsonObject(with: Data(
                "{\"type\":\"pane_read\",\"read\":{\"pane_id\":\"w5:p17\",\"text\":\"hello\\n\"}}".utf8))
            TestHarness.expect(try! HerdrProtocol.decodePaneText(value) == "hello\n",
                               "read text extracted")

            var threw = false
            do { _ = try HerdrProtocol.decodePaneText(["read": ["nope": 1]]) } catch { threw = true }
            TestHarness.expect(threw, "read result without text throws")
        }

        TestHarness.group("HerdrProtocol — params") {
            let p = HerdrProtocol.readParams(paneID: "w5:p17", source: "visible", lines: 40,
                                             stripANSI: false, format: "ansi")
            TestHarness.expect(p["pane_id"] as? String == "w5:p17", "pane_id set")
            TestHarness.expect(p["source"] as? String == "visible", "source set")
            TestHarness.expect(p["lines"] as? Int == 40, "lines set")
            // ANSI is preserved by default: the panel renders colours, so
            // stripping would throw away the formatting we want to show.
            TestHarness.expect(p["strip_ansi"] as? Bool == false, "ansi preserved for rendering")
            TestHarness.expect(p["format"] as? String == "ansi", "ansi format requested")

            let noLines = HerdrProtocol.readParams(paneID: "a")
            TestHarness.expect(noLines["lines"] == nil, "lines omitted when unspecified")
            TestHarness.expect(noLines["source"] as? String == "visible", "source defaults to visible")

            let input = HerdrProtocol.textParams(paneID: "w5:p17", text: "ls -la")
            TestHarness.expect(input["pane_id"] as? String == "w5:p17", "text carries pane_id")
            TestHarness.expect(input["text"] as? String == "ls -la", "text carries text")
            TestHarness.expect(input.count == 2, "text params are exactly pane_id + text")

            let keys = HerdrProtocol.keysParams(paneID: "w5:p17", keys: ["Enter"])
            TestHarness.expect((keys["keys"] as? [String])?.first == "Enter", "keys carried")

            let sub = HerdrProtocol.subscribeParams(["pane.updated"])
            let items = sub["subscriptions"] as? [[String: String]]
            TestHarness.expect(items?.first?["type"] == "pane.updated", "subscription shape matches schema")
        }

        TestHarness.group("HerdrError — fallback classification") {
            // Only "not there" justifies silently falling back to the local PTY.
            // A protocol error means herdr answered, which the user should see.
            TestHarness.expect(HerdrError.unavailable("no socket").isUnavailable,
                               "unavailable qualifies for fallback")
            TestHarness.expect(!HerdrError.remote(code: "x", message: "y").isUnavailable,
                               "remote error does not qualify for fallback")
            TestHarness.expect(!HerdrError.malformed("z").isUnavailable,
                               "malformed reply does not qualify for fallback")
        }

        TestHarness.group("HerdrSession — follow, poll, redraw suppression") {
            let fake = FakeTransport()
            let session = HerdrSession(transport: fake)

            fake.responses[.paneList] = [
                "panes": [
                    ["pane_id": "w1:p1", "focused": false, "terminal_title_stripped": "one"],
                    ["pane_id": "w1:p2", "focused": true, "terminal_title_stripped": "two"],
                ]
            ]
            let panes = try! session.refreshPanes()
            TestHarness.expect(panes.count == 2, "two panes listed")
            TestHarness.expect(session.focusedPane?.paneID == "w1:p2",
                               "focusedPane prefers the pane herdr focuses")

            // Nothing followed yet — polling is a no-op, not a crash.
            TestHarness.expect(try! session.pollOnce() == nil, "poll without a followed pane returns nil")

            var paints: [String] = []
            session.onScreenChange = { paints.append($0) }
            session.follow(paneID: "w1:p1")
            if case .connected(let paneID) = session.state {
                TestHarness.expect(paneID == "w1:p1", "state reports the followed pane")
            } else {
                TestHarness.expect(false, "follow sets connected state")
            }

            fake.responses[.paneRead] = ["read": ["pane_id": "w1:p1", "text": "screen one\n"]]
            TestHarness.expect(try! session.pollOnce() == "screen one\n", "first poll returns the screen")
            TestHarness.expect(paints.count == 1, "first poll repaints")

            // Same text again: this is the whole point of the cache — a redraw on
            // every poll would flicker the panel and burn CPU.
            TestHarness.expect(try! session.pollOnce() == nil, "unchanged screen returns nil")
            TestHarness.expect(paints.count == 1, "unchanged screen does not repaint")

            fake.responses[.paneRead] = ["read": ["pane_id": "w1:p1", "text": "screen two\n"]]
            TestHarness.expect(try! session.pollOnce() == "screen two\n", "changed screen returns text")
            TestHarness.expect(paints.count == 2, "changed screen repaints")

            // Following a different pane must repaint even if the text is
            // identical, or the panel would keep showing the old pane.
            fake.responses[.paneRead] = ["read": ["pane_id": "w1:p2", "text": "screen two\n"]]
            session.follow(paneID: "w1:p2")
            TestHarness.expect(try! session.pollOnce() == "screen two\n",
                               "following another pane repaints identical text")
            TestHarness.expect(paints.count == 3, "pane switch forces a repaint")

            TestHarness.expect(fake.calls.contains(.paneRead), "poll used pane.read")
        }

        TestHarness.group("HerdrSession — input") {
            let fake = FakeTransport()
            let session = HerdrSession(transport: fake)
            session.follow(paneID: "w1:p1")
            fake.responses[.paneSendText] = ["type": "ok"]
            fake.responses[.paneSendKeys] = ["type": "ok"]

            try! session.sendText("ls")
            let textCall = fake.callsWithParams.last { $0.method == .paneSendText }
            TestHarness.expect(textCall?.params["text"] as? String == "ls", "typed text sent")
            TestHarness.expect(textCall?.params["pane_id"] as? String == "w1:p1", "text sent to followed pane")

            try! session.sendKeys(["Enter"])
            let keyCall = fake.callsWithParams.last { $0.method == .paneSendKeys }
            TestHarness.expect((keyCall?.params["keys"] as? [String])?.first == "Enter", "Enter key sent")

            // Typing changes the screen, so the stale cache must be cleared or the
            // next poll would suppress the echo of what the user just typed.
            fake.responses[.paneRead] = ["read": ["pane_id": "w1:p1", "text": "same\n"]]
            _ = try! session.pollOnce()
            TestHarness.expect(try! session.pollOnce() == nil, "cache holds after a quiet poll")
            try! session.sendText("x")
            TestHarness.expect(try! session.pollOnce() == "same\n",
                               "input invalidates the cache so the next poll repaints")

            // With no pane followed there is nothing to type into; this must be a
            // silent no-op rather than an error.
            let idle = HerdrSession(transport: FakeTransport())
            try! idle.sendText("ignored")
            try! idle.sendKeys(["Enter"])
            TestHarness.expect(true, "input without a followed pane is a no-op")
        }

        TestHarness.group("HerdrSession — concurrent polls are serialized") {
            // The app polls on a background timer while keystrokes arrive on the
            // main thread. Without the serial queue, two pollers can both read the
            // same screen and both compare it against a stale `lastScreen`, so a
            // single change gets painted twice (and the redraw suppression breaks).
            let fake = FakeTransport()
            fake.readResponses = ["s1\n", "s2\n", "s3\n", "s4\n"]

            let session = HerdrSession(transport: fake)
            let lock = NSLock()
            var screens: [String] = []
            session.onScreenChange = { screen in
                lock.lock()
                screens.append(screen)
                lock.unlock()
            }
            session.follow(paneID: "w1:p1")

            // 16 threads each draining the poll path.
            let group = DispatchGroup()
            for _ in 0..<16 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<10 { _ = try? session.pollOnce() }
                    group.leave()
                }
            }
            group.wait()

            // The fake holds at its last entry once exhausted, so the only possible
            // correct outcome is one redraw per distinct screen: exactly 4.
            TestHarness.expect(screens.count == 4,
                "each distinct screen redraws exactly once — got \(screens.count), expected 4")
            TestHarness.expect(screens == ["s1\n", "s2\n", "s3\n", "s4\n"],
                "screens arrive in order with no duplicates — got \(screens)")
            TestHarness.expect(session.followedPaneID == "w1:p1",
                "concurrent polls leave the followed pane intact")
        }

        TestHarness.group("HerdrSession — concurrent input and polling") {
            // Typing on the main thread while the poll timer fires must not corrupt
            // session state. `sendText` deliberately clears the redraw cache, so the
            // invariant here is stability: the followed pane survives, input keeps
            // reaching the transport, and nothing deadlocks the serial queue.
            let fake = FakeTransport()
            fake.readResponses = ["only\n"]

            let session = HerdrSession(transport: fake)
            session.follow(paneID: "w1:p1")

            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<20 { _ = try? session.pollOnce() }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<20 { try? session.sendText("x") }
                    group.leave()
                }
            }
            // `group.wait()` returning at all is the deadlock check.
            let waited = group.wait(timeout: .now() + 10) == .success

            TestHarness.expect(waited, "concurrent poll and input complete without deadlock")
            TestHarness.expect(session.followedPaneID == "w1:p1",
                "concurrent input leaves the followed pane intact")
            TestHarness.expect(fake.calls.filter { $0 == .paneSendText }.count == 160,
                "every keystroke reached the transport — got \(fake.calls.filter { $0 == .paneSendText }.count), expected 160")
        }

        TestHarness.group("HerdrSession — disconnect handling") {
            let fake = FakeTransport()
            let session = HerdrSession(transport: fake)
            session.follow(paneID: "w1:p1")

            var states: [HerdrSession.State] = []
            session.onStateChange = { states.append($0) }

            // A protocol error means herdr answered — keep the session, report it.
            session.handleFailure(HerdrError.remote(code: "boom", message: "bad"))
            if case .connected = session.state {
                TestHarness.expect(true, "protocol error keeps the session connected")
            } else {
                TestHarness.expect(false, "protocol error keeps the session connected")
            }
            TestHarness.expect(states.isEmpty, "no state change on a protocol error")

            // A vanished herdr must drop out of herdr mode so the panel can fall
            // back instead of showing a frozen screen.
            session.handleFailure(HerdrError.unavailable("herdr gone"))
            if case let .disconnected(reason) = session.state {
                TestHarness.expect(reason.contains("gone"), "disconnect records the reason")
            } else {
                TestHarness.expect(false, "unavailable error disconnects")
            }
            TestHarness.expect(session.followedPaneID == nil, "disconnect stops following")
            TestHarness.expect(try! session.pollOnce() == nil, "poll after disconnect is a no-op")
            TestHarness.expect(states.count == 1, "disconnect reported once")

            // The event-stream drop path calls markDisconnected directly.
            session.markDisconnected(reason: "event stream closed")
            if case .disconnected(let reason) = session.state {
                TestHarness.expect(reason == "event stream closed", "markDisconnected records its reason")
            } else {
                TestHarness.expect(false, "markDisconnected disconnects")
            }
        }
    }
}

/// Stand-in for `HerdrClient` so session logic is testable without herdr.
///
/// Only "there is nothing to call" and "it changed under me" behaviour is worth
/// faking; the socket itself is covered by `--herdr-test` against the real
/// server.
///
/// Deliberately not thread-safe: `HerdrSession` funnels every call through its
/// own serial queue, so the fake is only ever touched from one thread at a time.
/// That is itself a nice property to rely on in tests.
private final class FakeTransport: HerdrTransport {
    var responses: [HerdrProtocol.Method: Any] = [:]
    var errorToThrow: Error?

    /// Successive replies for `paneRead`, consumed one per call and held at the
    /// last entry. Lets a test model a screen that changes over time.
    var readResponses: [String] = []
    private var readIndex = 0

    private(set) var calls: [HerdrProtocol.Method] = []
    private(set) var callsWithParams: [(method: HerdrProtocol.Method, params: [String: Any])] = []

    func call(_ method: HerdrProtocol.Method, params: [String: Any]) throws -> Any {
        calls.append(method)
        callsWithParams.append((method, params))
        if let errorToThrow { throw errorToThrow }
        if method == .paneRead, !readResponses.isEmpty {
            let text = readResponses[min(readIndex, readResponses.count - 1)]
            readIndex += 1
            return ["read": ["pane_id": params["pane_id"] ?? "", "text": text]]
        }
        guard let response = responses[method] else {
            throw HerdrError.malformed("FakeTransport has no response for \(method.rawValue)")
        }
        return response
    }
}
