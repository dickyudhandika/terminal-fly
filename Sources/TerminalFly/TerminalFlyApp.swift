import AppKit
import ServiceManagement

/// Application entry point.
///
/// Terminal Fly is a menu-bar accessory: no Dock icon, no main menu window.
/// The only visible surface is the floating panel (plus the menu bar item
/// added in Step 6).
@main
enum TerminalFlyMain {
    static func main() {
        // Headless PTY check: `TerminalFly --selftest`. Runs before any AppKit
        // setup so it works over SSH / in CI with no window server session.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }

        // Live herdr integration check: `TerminalFly --herdr-test`. Needs a
        // running herdr; exits 2 (not 1) when herdr is simply absent, because
        // that is a supported state, not a failure.
        if CommandLine.arguments.contains("--herdr-test") {
            exit(HerdrSelfTest.run())
        }

        // Pure-logic tests: `TerminalFly --test`. No window server needed.
        if CommandLine.arguments.contains("--test") {
            GeometryTests.run()
            HotkeyTests.run()
            ShellTests.run()
            HerdrTests.run()
            exit(TestHarness.finish())
        }

        // Tests that need a real window server: `TerminalFly --uitest`.
        if CommandLine.arguments.contains("--uitest") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            exit(UITests.run())
        }

        // End-to-end herdr render check: `TerminalFly --herdr-uitest`.
        // Enters herdr mode in a real window, follows a pane, renders it, and
        // asserts the panel actually shows pane text. This is the Step 8
        // acceptance path — `--herdr-test` only proves the socket works.
        if CommandLine.arguments.contains("--herdr-uitest") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            exit(HerdrUITests.run())
        }

        // Launch-at-login check: `TerminalFly --logintest`. Needs the app in
        // /Applications; self-reversing, so it never leaves a stray login item.
        if CommandLine.arguments.contains("--logintest") {
            exit(LoginItemSelfTest.run())
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Marked `@MainActor` because every NSApplicationDelegate callback already
/// runs on the main thread, and the coordinator owns main-actor isolated state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The panel is the whole app; hiding it is not quitting.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.controller.saveFrame()
    }
}
