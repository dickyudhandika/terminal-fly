import AppKit

/// User-tunable preferences, persisted in `UserDefaults`.
///
/// A plain `ObservableObject` rather than `@AppStorage` bindings, because the
/// panel is an AppKit window, not a SwiftUI scene — the settings window needs to
/// push changes into the live `NSPanel`, which `@AppStorage` cannot do across
/// that boundary.
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    enum Key {
        static let fontName = "prefFontName"
        static let fontSize = "prefFontSize"
        static let opacity = "prefOpacity"
        static let shellExecutable = "prefShellExecutable"
        static let shellArguments = "prefShellArguments"
        static let workingDirectory = "prefWorkingDirectory"
        static let theme = "prefTheme"
        static let transparentWhenUnfocused = "prefTransparentWhenUnfocused"
    }

    enum Theme: String, CaseIterable, Identifiable {
        case dark, light, solarizedDark, solarizedLight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dark: return "Dark"
            case .light: return "Light"
            case .solarizedDark: return "Solarized Dark"
            case .solarizedLight: return "Solarized Light"
            }
        }

        /// (background, foreground, caret, selection background)
        var colors: (background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor) {
            switch self {
            case .dark:
                return (NSColor(calibratedWhite: 0.06, alpha: 1),
                        NSColor(calibratedWhite: 0.92, alpha: 1),
                        NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.75, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.45, alpha: 0.5))
            case .light:
                return (NSColor(calibratedWhite: 0.98, alpha: 1),
                        NSColor(calibratedWhite: 0.10, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.50, blue: 0.45, alpha: 1),
                        NSColor(calibratedRed: 0.70, green: 0.85, blue: 0.85, alpha: 0.6))
            case .solarizedDark:
                return (NSColor(calibratedRed: 0.0, green: 0.17, blue: 0.21, alpha: 1),
                        NSColor(calibratedRed: 0.51, green: 0.58, blue: 0.59, alpha: 1),
                        NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
                        NSColor(calibratedRed: 0.03, green: 0.21, blue: 0.26, alpha: 1))
            case .solarizedLight:
                return (NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.89, alpha: 1),
                        NSColor(calibratedRed: 0.40, green: 0.48, blue: 0.51, alpha: 1),
                        NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
                        NSColor(calibratedRed: 0.93, green: 0.91, blue: 0.83, alpha: 1))
            }
        }
    }

    @Published var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: Key.fontName) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Key.fontSize) }
    }

    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: Key.opacity) }
    }

    @Published var shellExecutable: String {
        didSet { UserDefaults.standard.set(shellExecutable, forKey: Key.shellExecutable) }
    }

    @Published var shellArguments: String {
        didSet { UserDefaults.standard.set(shellArguments, forKey: Key.shellArguments) }
    }

    @Published var workingDirectory: String {
        didSet { UserDefaults.standard.set(workingDirectory, forKey: Key.workingDirectory) }
    }

    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Key.theme) }
    }

    /// When on, the panel drops to a much lower opacity while another app has
    /// focus, so it recedes behind the design tool instead of competing with it.
    @Published var transparentWhenUnfocused: Bool {
        didSet { UserDefaults.standard.set(transparentWhenUnfocused, forKey: Key.transparentWhenUnfocused) }
    }

    private init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: Key.fontName) ?? "SFMono-Regular"
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 12.5
        opacity = defaults.object(forKey: Key.opacity) as? Double ?? 0.92
        shellExecutable = defaults.string(forKey: Key.shellExecutable)
            ?? ShellConfiguration.default().executable
        shellArguments = defaults.string(forKey: Key.shellArguments) ?? "-l"
        workingDirectory = defaults.string(forKey: Key.workingDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        theme = defaults.string(forKey: Key.theme).flatMap(Theme.init(rawValue:)) ?? .dark
        transparentWhenUnfocused = defaults.bool(forKey: Key.transparentWhenUnfocused)
    }

    /// The font to hand SwiftTerm, falling back to the system monospaced font
    /// when the requested family is not installed.
    var resolvedFont: NSFont {
        if let font = NSFont(name: fontName, size: fontSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// A `ShellConfiguration` built from the current settings.
    var shellConfiguration: ShellConfiguration {
        let args = shellArguments
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let directory = workingDirectory.isEmpty ? nil : workingDirectory
        return ShellConfiguration(
            executable: shellExecutable.isEmpty ? "/bin/zsh" : shellExecutable,
            arguments: args.isEmpty ? ["-l"] : args,
            workingDirectory: directory
        )
    }

    /// Fonts offered in the settings picker: every monospaced family installed
    /// on the machine, plus the system mono font, sorted by name.
    var availableMonospacedFonts: [String] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return (["SFMono-Regular"] + families).reduce(into: [String]()) { result, family in
            if !result.contains(family) { result.append(family) }
        }
    }
}
