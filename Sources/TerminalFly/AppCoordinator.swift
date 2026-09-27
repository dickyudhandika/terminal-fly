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
            onQuit: { NSApp.terminate(nil) }
        )
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
