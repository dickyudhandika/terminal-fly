import AppKit
import Carbon.HIToolbox

/// Named global-hotkey actions. String-backed so the raw value can be the
/// persistence and Carbon-registration key.
enum HotkeyAction: String, CaseIterable {
    case togglePanel
    case cycleCorner
    case increaseHeight
    case decreaseHeight

    var title: String {
        switch self {
        case .togglePanel: return "Show / hide panel"
        case .cycleCorner: return "Cycle corner"
        case .increaseHeight: return "Increase height"
        case .decreaseHeight: return "Decrease height"
        }
    }

    var defaultBinding: HotkeyBinding {
        switch self {
        case .togglePanel: return .defaultToggle
        case .cycleCorner: return .defaultCycleCorner
        case .increaseHeight: return .defaultHeightIncrease
        case .decreaseHeight: return .defaultHeightDecrease
        }
    }
}
