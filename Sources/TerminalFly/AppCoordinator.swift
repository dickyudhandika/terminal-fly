import AppKit
import SwiftUI

/// Wires the pieces together: panel, hotkeys, menu bar, settings, preferences.
///
/// Keeping this in one place (rather than in `AppDelegate`) means the settings
/// window and the menu bar can both reach the panel and the hotkey manager
/// without either owning the other.
@MainActor
final class AppCoordinator: NSObject {
    let preferences = PreferencesStore.shared
    let controller: PanelController
    let hotkeys: HotkeyManager

    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?
    private var focusObservers: [NSObjectProtocol] = []

    /// herdr integration (Step 8). `nil` until the user opts into herdr mode, so
    /// a machine without herdr pays nothing for it.
    private var herdrClient: HerdrClient?
    private var herdrSession: HerdrSession?
    private var herdrPollTimer: Timer?

    /// Last known pane list, populated off the main thread by `refreshHerdrPanes()`.
    /// The menu reads this so building the menu never blocks on the socket.
    private var cachedHerdrPanes: [HerdrProtocol.Pane] = []

    /// True while the panel is showing a herdr pane instead of its own shell.
    private(set) var isHerdrMode = false

    /// Test seam for `--herdr-uitest`: lets the test drive the disconnect path
    /// without killing the user's real herdr.
    var herdrSessionForTesting: HerdrSession? { herdrSession }

    override init() {
        controller = PanelController()
        hotkeys = HotkeyManager()
        super.init()

        applyPreferences()
        registerHotkeys()
        observeFocusChanges()

        menuBar = MenuBarController(content: self.buildMenu())
    }

    func start() {
        controller.show()
        // Populate the herdr pane list in the background. Deliberately in `start()`
        // rather than `init`: the menu reads a cache, and this is the earliest point
        // where I/O is safe.
        refreshHerdrPanes()
    }

    // MARK: - herdr mode (Step 8)

    /// True when a herdr socket is present, so the UI can offer the option.
    var herdrAvailable: Bool {
        FileManager.default.fileExists(atPath: HerdrProtocol.defaultSocketPath)
    }

    /// Enters herdr mode, following `paneID` (or herdr's focused pane).
    ///
    /// Returns an error string when herdr cannot be reached, so the caller can
    /// show a message. On success the panel switches to the herdr display and a
    /// poll timer starts.
    @discardableResult
    func enterHerdrMode(paneID: String? = nil) -> String? {
        let client: HerdrClient
        if let existing = herdrClient {
            client = existing
        } else {
            client = HerdrClient()
            herdrClient = client
        }

        let session: HerdrSession
        if let existing = herdrSession {
            session = existing
        } else {
            session = HerdrSession(transport: client)
            herdrSession = session
            wireHerdrCallbacks(session)
        }

        do {
            let panes = try session.refreshPanes()
            guard let target = paneID ?? session.focusedPane?.paneID else {
                return "herdr is running but has no panes to show"
            }
            guard panes.contains(where: { $0.paneID == target }) || paneID != nil else {
                return "pane \(target) is no longer present"
            }
            session.follow(paneID: target)
        } catch {
            // Distinguish "no herdr" from "herdr answered with an error": the
            // first is a normal fallback, the second is worth telling the user.
            session.handleFailure(error)
            return (error as? HerdrError)?.description ?? "\(error)"
        }

        let display = controller.showHerdr()
        display.invalidateScreenCache()
        display.onInput = { [weak self] bytes in
            self?.forwardHerdrInput(bytes)
        }
        isHerdrMode = true
        startHerdrPolling()
        // Paint immediately rather than waiting a full tick.
        pollHerdrOnce()
        cachedHerdrPanes = session.panes
        refreshMenuBar()
        return nil
    }

    /// Leaves herdr mode and returns the panel to its own shell.
    func exitHerdrMode() {
        stopHerdrPolling()
        herdrSession?.unfollow()
        isHerdrMode = false
        controller.showStandalone()
        refreshMenuBar()
    }

    /// Wires session callbacks.
    ///
    /// Callbacks fire from *inside* the session's serial queue — which is a
    /// background thread during polling — so every body here hops to the main
    /// queue before touching AppKit. None of them call back into `session`
    /// synchronously, which would deadlock the non-reentrant queue.
    private func wireHerdrCallbacks(_ session: HerdrSession) {
        session.onScreenChange = { [weak self] screen in
            DispatchQueue.main.async {
                self?.controller.herdrSurface?.show(screen: screen)
            }
        }
        session.onStateChange = { [weak self] state in
            guard case let .disconnected(reason) = state else { return }
            // herdr vanished: show why, then hand the panel back to a working
            // shell so the user is never left with a dead pane.
            DispatchQueue.main.async {
                guard let self else { return }
                self.controller.herdrSurface?.showStatus("herdr disconnected: \(reason)\n\nFalling back to a local shell.")
                self.stopHerdrPolling()
                self.isHerdrMode = false
                self.controller.showStandalone()
                self.refreshMenuBar()
            }
        }
    }

    private func startHerdrPolling() {
        stopHerdrPolling()
        let interval = herdrSession?.minimumPollInterval ?? 0.4
        herdrPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHerdrOnce() }
        }
    }

    private func stopHerdrPolling() {
        herdrPollTimer?.invalidate()
        herdrPollTimer = nil
    }

    /// One poll tick. A socket read is blocking, so this runs off the main thread.
    ///
    /// Painting is handled by `onScreenChange`, which the session fires from
    /// inside the poll — so there is deliberately no second paint here.
    private func pollHerdrOnce() {
        guard let session = herdrSession, isHerdrMode else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try session.pollOnce()
            } catch {
                session.handleFailure(error)
            }
        }
    }

    /// Forwards raw keystroke bytes to herdr.
    ///
    /// Bytes arrive from SwiftTerm's `send` hook already encoded for the
    /// terminal, so they are passed through as text rather than reinterpreted.
    private func forwardHerdrInput(_ bytes: ArraySlice<UInt8>) {
        guard let session = herdrSession else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        do {
            try session.sendText(text)
        } catch {
            session.handleFailure(error)
        }
    }

    // MARK: - Preferences → panel

    func applyPreferences() {
        let theme = preferences.theme.colors
        controller.surface.applyFont(preferences.resolvedFont)
        controller.surface.applyColors(
            background: theme.background,
            foreground: theme.foreground,
            caret: theme.caret,
            selection: theme.selection
        )
        controller.panel.backgroundColor = theme.background
        controller.setOpacity(CGFloat(preferences.opacity))
    }

    /// Applies the "transparent when unfocused" preference. Only meaningful when
    /// the user turned it on; otherwise opacity is whatever the slider says.
    private func updateFocusOpacity(isFocused: Bool) {
        guard preferences.transparentWhenUnfocused else { return }
        let base = CGFloat(preferences.opacity)
        controller.setOpacity(isFocused ? base : base * 0.45)
    }

    private func observeFocusChanges() {
        let center = NotificationCenter.default
        // The panel's own key state is the signal we want, not the app's
        // activation state: as an accessory app, Terminal Fly is "inactive"
        // almost all the time even while you are typing in the panel.
        focusObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: controller.panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFocusOpacity(isFocused: true) }
        })
        focusObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: controller.panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFocusOpacity(isFocused: false) }
        })
    }

    // MARK: - Hotkeys

    func registerHotkeys() {
        for action in HotkeyAction.allCases {
            let binding = storedBinding(for: action)
            register(action: action, binding: binding)
        }
    }

    private func register(action: HotkeyAction, binding: HotkeyBinding) {
        if let error = hotkeys.register(action: action.rawValue, binding: binding, handler: { [weak self] in
            self?.perform(action)
        }) {
            DebugLog.write("hotkey \(action.rawValue) unavailable: \(error)")
        }
    }

    /// Re-register one action, returning an error message on conflict.
    func rebind(action: HotkeyAction, to binding: HotkeyBinding) -> String? {
        hotkeys.unregister(action: action.rawValue)
        if let error = hotkeys.register(action: action.rawValue, binding: binding, handler: { [weak self] in
            self?.perform(action)
        }) {
            // Put the previous binding back so the user is never left with a
            // dead hotkey after a rejected recording.
            register(action: action, binding: storedBinding(for: action))
            return error
        }
        persist(binding, for: action)
        refreshMenuBar()
        return nil
    }

    func resetHotkeys() {
        for action in HotkeyAction.allCases {
            hotkeys.unregister(action: action.rawValue)
            persist(action.defaultBinding, for: action)
            register(action: action, binding: action.defaultBinding)
        }
        refreshMenuBar()
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .togglePanel: controller.toggle()
        case .cycleCorner: controller.cycleCorner()
        case .increaseHeight: controller.grow()
        case .decreaseHeight: controller.shrink()
        }
        refreshMenuBar()
    }

    // MARK: - Hotkey persistence

    private func storedBinding(for action: HotkeyAction) -> HotkeyBinding {
        guard let data = UserDefaults.standard.data(forKey: "hotkey.\(action.rawValue)"),
              let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data) else {
            return action.defaultBinding
        }
        return binding
    }

    private func persist(_ binding: HotkeyBinding, for action: HotkeyAction) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        UserDefaults.standard.set(data, forKey: "hotkey.\(action.rawValue)")
    }

    // MARK: - Menu bar

    private func buildMenu() -> MenuBarMenu {
        MenuBarMenu(
            store: preferences,
            controller: controller,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onRestartShell: { [weak self] in self?.restartShell() },
            onQuit: { NSApp.terminate(nil) },
            // Read from the cache, never from the socket: `buildMenu()` runs inside
            // `init`, so a blocking call here would stall app launch for the whole
            // socket timeout whenever herdr is present but wedged.
            herdrPanes: cachedHerdrPanes,
            isHerdrMode: isHerdrMode,
            // Only offered when herdr is actually installed — a nil handler hides
            // the whole section rather than showing a dead menu.
            onEnterHerdr: herdrAvailable ? { [weak self] paneID in
                guard let self else { return }
                if let error = self.enterHerdrMode(paneID: paneID) {
                    self.controller.herdrSurface?.showStatus("herdr: \(error)")
                }
            } : nil,
            onExitHerdr: { [weak self] in self?.exitHerdrMode() }
        )
    }

    /// Refreshes `cachedHerdrPanes` off the main thread.
    ///
    /// The menu is built synchronously (and once inside `init`), so it must never
    /// touch the socket. This populates the cache in the background and rebuilds
    /// the menu when the list arrives.
    func refreshHerdrPanes() {
        guard herdrAvailable else {
            cachedHerdrPanes = []
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A short timeout keeps a wedged-but-present herdr from tying up the
            // background thread; nothing depends on this call completing.
            let panes: [HerdrProtocol.Pane]
            do {
                let value = try HerdrClient().call(.paneList, params: [:], timeout: 1.5)
                panes = try HerdrProtocol.decodePaneList(value)
            } catch {
                panes = []
            }
            DispatchQueue.main.async {
                guard let self, panes != self.cachedHerdrPanes else { return }
                self.cachedHerdrPanes = panes
                self.refreshMenuBar()
            }
        }
    }

    private func refreshMenuBar() {
        menuBar?.updateContent(buildMenu())
    }

    func restartShell() {
        controller.surface.applyConfiguration(preferences.shellConfiguration)
        controller.surface.restartShell()
    }

    // MARK: - Settings window

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            store: preferences,
            hotkeys: hotkeys,
            onApplyAppearance: { [weak self] in self?.applyPreferences() },
            onRebindHotkey: { [weak self] action, binding in
                self?.rebind(action: action, to: binding)
            },
            onResetHotkeys: { [weak self] in self?.resetHotkeys() },
            onRestartShell: { [weak self] in self?.restartShell() },
            onLaunchAtLoginChanged: { _ in }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal Fly Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
