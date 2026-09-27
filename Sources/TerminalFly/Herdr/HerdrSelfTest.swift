import Foundation

/// Live integration check against a running herdr: `TerminalFly --herdr-test`.
///
/// Unlike `--test`, this talks to the real socket, so it only passes when herdr
/// is actually running. Exit codes distinguish the two cases:
///
///   0 = pass, 1 = fail (connected but something is wrong),
///   2 = skip (herdr not running — expected on a machine without it, and the
///       app is designed to fall back to a standalone shell in that case).
enum HerdrSelfTest {
    static func run() -> Int32 {
        print("herdr-test: socket = \(HerdrProtocol.defaultSocketPath)")

        let client = HerdrClient()
        var panes: [HerdrProtocol.Pane] = []

        do {
            let value = try client.call(.paneList)
            panes = try HerdrProtocol.decodePaneList(value)
        } catch let error as HerdrError where error.isUnavailable {
            print("herdr-test: SKIP — \(error.description)")
            print("herdr-test: herdr is not running; the app falls back to standalone mode.")
            return 2
        } catch {
            print("herdr-test: FAIL — pane.list: \(error)")
            return 1
        }

        print("herdr-test: pane.list OK — \(panes.count) pane(s)")
        for pane in panes {
            print("herdr-test:   \(pane.paneID)  \(pane.displayName)  [\(pane.agentStatus ?? "-")]")
        }

        guard let target = panes.first else {
            print("herdr-test: SKIP — herdr is running but reports no panes")
            return 2
        }

        // The connection model is one request per connection, so this second call
        // is itself a regression test: if someone reintroduces a shared socket,
        // this is what catches it (it read "not connected" the first time).
        do {
            let value = try client.call(.paneRead,
                                        params: HerdrProtocol.readParams(paneID: target.paneID,
                                                                         source: "visible",
                                                                         lines: 3))
            let text = try HerdrProtocol.decodePaneText(value)
            print("herdr-test: pane.read OK — \(text.count) chars from \(target.paneID)")
            let firstLine = text.split(separator: "\n").last.map(String.init) ?? ""
            print("herdr-test: last line: \(firstLine)")
        } catch {
            print("herdr-test: FAIL — pane.read (second call on a fresh connection): \(error)")
            return 1
        }

        // A third call proves the pattern holds for more than two in a row.
        do {
            let value = try client.call(.paneList)
            let again = try HerdrProtocol.decodePaneList(value)
            print("herdr-test: third call OK — \(again.count) pane(s)")
        } catch {
            print("herdr-test: FAIL — third call: \(error)")
            return 1
        }

        print("herdr-test: PASS — three sequential requests, each on its own connection")
        return 0
    }
}
