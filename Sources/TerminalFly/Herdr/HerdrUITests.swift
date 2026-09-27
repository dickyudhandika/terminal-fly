import AppKit
import Foundation

/// End-to-end herdr render check: `TerminalFly --herdr-uitest`.
///
/// Proves the Step 8 acceptance path in a real window with a real herdr:
///
///   1. create an isolated scratch workspace + pane (never the user's panes)
///   2. point the coordinator at it and enter herdr mode
///   3. write to that pane through herdr
///   4. assert the *panel's own terminal buffer* shows the new output
///   5. leave herdr mode, tear the scratch workspace down
///
/// Step 4 is the part that matters: it reads the rendered screen out of the
/// SwiftTerm view, so a failure to render is caught rather than assumed.
///
/// Exit codes: 0 pass, 1 fail, 2 skip (herdr not running or no window server).
@MainActor
enum HerdrUITests {
    static func run() -> Int32 {
        guard let scratch = ScratchWorkspace() else {
            print("herdr-uitest: SKIP — could not create a scratch herdr workspace")
            return 2
        }
        defer { scratch.destroy() }

        let coordinator = AppCoordinator()
        coordinator.start()

        guard let panel = coordinator.controller.panel as NSWindow? else {
            print("herdr-uitest: FAIL — no panel")
            return 1
        }
        _ = panel // panel exists; the assertions below read the surface buffer

        print("herdr-uitest: scratch pane = \(scratch.paneID)")

        // Enter herdr mode following the scratch pane.
        if let error = coordinator.enterHerdrMode(paneID: scratch.paneID) {
            print("herdr-uitest: FAIL — enterHerdrMode: \(error)")
            return 1
        }

        guard coordinator.isHerdrMode else {
            print("herdr-uitest: FAIL — not in herdr mode after enterHerdrMode")
            return 1
        }
        guard let surface = coordinator.controller.herdrSurface else {
            print("herdr-uitest: FAIL — no herdr surface installed")
            return 1
        }

        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ok   \(label)" : "  FAIL \(label)")
            if !condition { failures += 1 }
        }

        check(coordinator.controller.isHerdrMode, "panel is showing the herdr surface")

        // Pump the runloop so the poll timer fires and paints.
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        pump(2.0)
        let initial = surface.screenText().trimmingCharacters(in: .whitespacesAndNewlines)
        check(!initial.isEmpty, "panel rendered the scratch pane's screen")

        // Write a unique marker into the pane, through herdr, and confirm the
        // panel shows it. This is the full loop: herdr → poll → render.
        let marker = "TF_HERDR_UITEST_\(Int(Date().timeIntervalSince1970) % 100000)"
        scratch.sendCommand("echo \(marker)")

        var sawMarker = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            pump(0.4)
            if surface.screenText().contains(marker) {
                sawMarker = true
                break
            }
        }
        check(sawMarker, "panel shows output written through herdr (\(marker))")

        // ---- Typing path: keystrokes must reach the herdr pane ----
        //
        // Drive the surface's own input hook, which is what SwiftTerm calls when
        // the user types. This is the "type in the panel → input reaches herdr"
        // acceptance criterion; it must NOT be tested by calling
        // `scratch.sendCommand`, or it would pass without the panel being wired.
        let typed = "TF_HERDR_TYPED_\(Int(Date().timeIntervalSince1970) % 100000)"
        surface.simulateTyping("echo \(typed)\r")

        var sawTyped = false
        let typedDeadline = Date().addingTimeInterval(8)
        while Date() < typedDeadline {
            pump(0.4)
            if surface.screenText().contains(typed) {
                sawTyped = true
                break
            }
        }
        check(sawTyped, "typing in the panel reached the herdr pane (\(typed))")

        // Explicit exit must also restore the standalone shell.
        coordinator.exitHerdrMode()
        check(!coordinator.isHerdrMode, "leaving herdr mode clears the flag")
        check(!coordinator.controller.isHerdrMode, "panel is back on the standalone surface")

        // Re-enter so the disconnect path below has something to leave.
        if coordinator.enterHerdrMode(paneID: scratch.paneID) != nil {
            print("herdr-uitest: FAIL — could not re-enter herdr mode for the disconnect check")
            return 1
        }
        pump(0.6)

        // ---- Disconnect path ----
        //
        // Point the session at a socket that is gone and confirm the coordinator
        // leaves herdr mode instead of freezing on a stale screen.
        coordinator.controller.herdrSurface?.invalidateScreenCache()
        coordinator.herdrSessionForTesting?.markDisconnected(reason: "herdr went away (test)")
        pump(1.0)
        check(!coordinator.isHerdrMode, "herdr disconnect leaves herdr mode")
        check(!coordinator.controller.isHerdrMode, "panel fell back to the standalone surface")

        print("----------------------------------------")
        if failures > 0 {
            print("FAIL: \(failures) check(s) failed")
            return 1
        }
        print("PASS: herdr render path verified end to end")
        return 0
    }
}

/// An isolated herdr workspace used only by the test.
///
/// Exists so no test ever writes into a pane the user is working in — the first
/// version of this work injected keystrokes into the live session's own pane,
/// which is exactly the mistake this type prevents.
@MainActor
private final class ScratchWorkspace {
    let workspaceID: String
    let paneID: String
    private let client = HerdrClient()

    init?() {
        do {
            let created = try client.call(.workspaceCreate, params: ["label": "tf-uitest", "focus": false])
            guard let workspace = (created as? [String: Any])?["workspace"] as? [String: Any],
                  let workspaceID = workspace["workspace_id"] as? String else { return nil }
            self.workspaceID = workspaceID

            let tab = try client.call(.tabCreate, params: ["workspace_id": workspaceID, "label": "tf-uitest", "focus": false])
            guard let root = (tab as? [String: Any])?["root_pane"] as? [String: Any],
                  let paneID = root["pane_id"] as? String else { return nil }
            self.paneID = paneID
        } catch {
            print("herdr-uitest: scratch workspace failed: \(error)")
            return nil
        }
    }

    func sendCommand(_ command: String) {
        _ = try? client.call(.paneSendText, params: HerdrProtocol.textParams(paneID: paneID, text: command + "\n"))
    }

    func destroy() {
        _ = try? client.call(.workspaceClose, params: ["workspace_id": workspaceID])
    }
}
