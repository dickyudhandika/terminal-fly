import Foundation
import ServiceManagement

/// Behavioural check for the "Launch at login" toggle: `TerminalFly --logintest`.
///
/// Launch at login was a documented gap because `SMAppService` only works when the
/// app lives in a stable location — running straight from `build/` fails. This
/// flag registers, verifies, and unregisters a login item so the real behaviour is
/// measured instead of assumed.
///
/// It is deliberately self-reversing: the login item is removed again before the
/// process exits, so running it never leaves the machine launching Terminal Fly at
/// boot without the user asking for it.
///
/// Exit codes: 0 pass, 1 fail, 2 skip (not running from a stable location).
enum LoginItemSelfTest {
    static func run() -> Int32 {
        let service = SMAppService.mainApp
        let bundlePath = Bundle.main.bundlePath

        print("logintest: bundle = \(bundlePath)")
        print("logintest: identifier = \(Bundle.main.bundleIdentifier ?? "<none>")")

        let initial = service.status
        print("logintest: initial status = \(describe(initial))")

        // SMAppService refuses to register an app that is not in a stable
        // location. Detect that up front so the failure is reported as "needs
        // /Applications" rather than an opaque error from the API.
        guard bundlePath.hasPrefix("/Applications/") else {
            print("logintest: SKIP — app is not in /Applications")
            print("logintest: SMAppService requires a stable install location; copy the")
            print("logintest: app to /Applications and re-run to exercise this path.")
            return 2
        }

        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ok   \(label)" : "  FAIL \(label)")
            if !condition { failures += 1 }
        }

        // Always leave the machine as we found it, even if a check fails or this
        // process dies partway through.
        defer {
            if service.status == .enabled {
                try? service.unregister()
            }
        }

        // --- register ---
        do {
            try service.register()
        } catch {
            print("logintest: FAIL — register threw: \(error.localizedDescription)")
            return 1
        }
        check(service.status == .enabled, "status is .enabled after register")
        check(service.status != initial || initial == .enabled,
              "status changed from its initial value")

        // Deliberately no `SMAppService.openSystemSettingsLoginItems()` check
        // here: it asserts nothing and pops the user's System Settings window
        // open as a side effect of running a self-test.

        // --- unregister must be the inverse ---
        do {
            try service.unregister()
        } catch {
            print("logintest: FAIL — unregister threw: \(error.localizedDescription)")
            return 1
        }
        check(service.status != .enabled, "status is no longer .enabled after unregister")

        print("----------------------------------------")
        if failures > 0 {
            print("FAIL: \(failures) check(s) failed")
            return 1
        }
        print("PASS: login item registers and unregisters")
        return 0
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
