import SwiftUI

/// Live-applied appearance settings.
///
/// Everything here writes straight through to `PreferencesStore`, and the panel
/// observes the store — so a slider change re-renders the panel while the user
/// is still dragging, which is the behaviour the plan asks to verify.
struct AppearanceSettings: View {
    @ObservedObject var store: PreferencesStore
    /// Applied immediately by the settings window (the panel may be hidden).
    var onApply: () -> Void

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $store.fontName) {
                    ForEach(store.availableMonospacedFonts, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: $store.fontSize, in: 8...28, step: 0.5) {
                        Text("Size")
                    }
                    Text(String(format: "%.1f", store.fontSize))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Preview: the quick brown fox 0123")
                    .font(.custom(store.fontName, size: store.fontSize))
                    .lineLimit(1)
            }

            Section("Theme") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(PreferencesStore.Theme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Window") {
                HStack {
                    Text("Opacity")
                    Slider(value: $store.opacity, in: 0.2...1.0) {
                        Text("Opacity")
                    }
                    Text("\(Int(store.opacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Transparent when unfocused", isOn: $store.transparentWhenUnfocused)
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.fontName) { onApply() }
        .onChange(of: store.fontSize) { onApply() }
        .onChange(of: store.opacity) { onApply() }
        .onChange(of: store.theme) { onApply() }
        .onChange(of: store.transparentWhenUnfocused) { onApply() }
    }
}
