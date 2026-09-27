import SwiftUI

/// Hotkey recording and conflict reporting.
///
/// The important behaviour is conflict detection (plan Risk 4): when a combo is
/// already owned by another app or by macOS, `RegisterEventHotKey` returns
/// `eventHotKeyExistsErr`, and the user must see that instead of silently
/// getting a dead binding.
struct HotkeySettings: View {
    let manager: HotkeyManager
    /// Re-registers a single action and returns an error message, or nil.
    var onRebind: (HotkeyAction, HotkeyBinding) -> String?
    var onReset: () -> Void

    @State private var recording: HotkeyAction?
    @State private var monitor: Any?
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Click Record, then press the combination you want.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(HotkeyAction.allCases, id: \.self) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    Text(manager.currentBinding(for: action.rawValue)?.display
                         ?? action.defaultBinding.display)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Button(recording == action ? "Press keys…" : "Record") {
                        recording == action ? stopRecording() : startRecording(action)
                    }
                }
                .id("\(action.rawValue)-\(revision)")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Divider()
            Button("Reset to defaults") {
                onReset()
                error = nil
                revision += 1
            }
        }
        .padding()
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: HotkeyAction) {
        stopRecording()
        recording = action
        error = nil
        // A *local* monitor is right here: while recording we want the keys in
        // this window only. (Global hotkeys still need Carbon — see
        // HotkeyManager — but recording does not.)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Ignore a bare modifier press; wait for a real key.
            let modifiers = HotkeyDisplay.carbonModifiers(for: event)
            guard modifiers != 0 else { return nil }

            let binding = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                display: HotkeyDisplay.string(for: event)
            )
            if let message = onRebind(action, binding) {
                error = message
            } else {
                error = nil
            }
            stopRecording()
            revision += 1
            return nil // swallow the keystroke
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = nil
    }
}
