import SwiftUI
import ServiceManagement

/// The Settings window: General / Appearance / Hotkeys / Shell.
struct SettingsView: View {
    @ObservedObject var store: PreferencesStore
    let hotkeys: HotkeyManager
    var onApplyAppearance: () -> Void
    var onRebindHotkey: (HotkeyAction, HotkeyBinding) -> String?
    var onResetHotkeys: () -> Void
    var onRestartShell: () -> Void
    var onLaunchAtLoginChanged: (Bool) -> Void

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings(store: store, onApply: onApplyAppearance)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            HotkeySettings(manager: hotkeys,
                           onRebind: onRebindHotkey,
                           onReset: onResetHotkeys)
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            shellTab
                .tabItem { Label("Shell", systemImage: "terminal") }
        }
        .frame(width: 520, height: 420)
        .onAppear { refreshLaunchAtLogin() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        setLaunchAtLogin(newValue)
                    }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section("Panel") {
                Button("Show panel") {
                    NSApp.activate(ignoringOtherApps: false)
                }
                Text("Global hotkeys are listed in the Hotkeys tab. The panel floats above all other apps; clicking it lets you type without moving focus away from your design tool.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shell

    private var shellTab: some View {
        Form {
            Section("Shell") {
                TextField("Executable", text: $store.shellExecutable)
                    .font(.system(.body, design: .monospaced))
                TextField("Arguments", text: $store.shellArguments)
                    .font(.system(.body, design: .monospaced))
                TextField("Working directory", text: $store.workingDirectory)
                    .font(.system(.body, design: .monospaced))
                Text("Arguments are split on spaces. Keep `-l` to run a login shell, which is what loads your PATH from .zprofile/.zshrc — without it, commands installed via Homebrew, nvm or pnpm will not be found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Apply and restart shell") { onRestartShell() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Launch at login (SMAppService)

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            launchAtLoginError = nil
            launchAtLogin = SMAppService.mainApp.status == .enabled
            onLaunchAtLoginChanged(launchAtLogin)
        } catch {
            // SMAppService requires the app to be in /Applications (or another
            // stable location) and properly signed. Running straight out of
            // build/ is the usual cause here.
            launchAtLoginError = "Could not change login item: \(error.localizedDescription) "
                + "Move Terminal Fly to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
