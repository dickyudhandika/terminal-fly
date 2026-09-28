import Foundation
import Carbon.HIToolbox

/// Tests for the pure parts of the hotkey layer: display formatting, Carbon
/// modifier translation, and binding persistence.
enum HotkeyTests {
    static func run() {
        TestHarness.group("HotkeyDisplay — key names") {
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_ANSI_P)), "P", "letter P")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_ANSI_C)), "C", "letter C")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_DownArrow)), "↓", "down arrow")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_UpArrow)), "↑", "up arrow")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_Space)), "Space", "space bar")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_Return)), "↩", "return key")
            TestHarness.equal(HotkeyDisplay.keyName(for: UInt32(kVK_ANSI_Slash)), "/",
                              "unshifted punctuation is readable")
            TestHarness.equal(HotkeyDisplay.keyName(for: 250), "Key 250",
                              "an unmapped key code degrades to a label, never crashes")
        }

        TestHarness.group("HotkeyAction — defaults match the plan") {
            TestHarness.equal(HotkeyAction.togglePanel.defaultBinding.display, "⌃⌥P",
                              "toggle is ⌃⌥P")
            TestHarness.equal(HotkeyAction.cycleCorner.defaultBinding.display, "⌃⌥C",
                              "cycle corner is ⌃⌥C")
            TestHarness.equal(HotkeyAction.increaseHeight.defaultBinding.display, "⌃⌥↓",
                              "increase height is ⌃⌥↓")
            TestHarness.equal(HotkeyAction.decreaseHeight.defaultBinding.display, "⌃⌥↑",
                              "decrease height is ⌃⌥↑")
            TestHarness.equal(HotkeyAction.increaseWidth.defaultBinding.display, "⌃⌥→",
                              "increase width is ⌃⌥→")
            TestHarness.equal(HotkeyAction.decreaseWidth.defaultBinding.display, "⌃⌥←",
                              "decrease width is ⌃⌥←")
            TestHarness.equal(HotkeyAction.toggleOpacity.defaultBinding.display, "⌃⌥O",
                              "cycle opacity is ⌃⌥O")
            TestHarness.equal(HotkeyAction.toggleFullscreen.defaultBinding.display, "⌃⌥F",
                              "toggle fullscreen is ⌃⌥F")
            TestHarness.equal(HotkeyAction.toggleSmallScreen.defaultBinding.display, "⌃⌥S",
                              "toggle small screen is ⌃⌥S")
            TestHarness.equal(HotkeyAction.closeApps.defaultBinding.display, "⌃⌥Q",
                              "close apps is ⌃⌥Q")

            // Every action must have a distinct default, otherwise registering
            // them would silently collide with itself.
            let displays = HotkeyAction.allCases.map(\.defaultBinding.display)
            TestHarness.equal(Set(displays).count, HotkeyAction.allCases.count,
                              "no two actions share a default binding")
        }

        TestHarness.group("HotkeyAction — every default uses control+option") {
            for action in HotkeyAction.allCases {
                let modifiers = action.defaultBinding.modifiers
                TestHarness.expect(modifiers & UInt32(controlKey) != 0,
                                   "\(action.rawValue) includes control")
                TestHarness.expect(modifiers & UInt32(optionKey) != 0,
                                   "\(action.rawValue) includes option")
                // ⌘ and ⌃ combos are far more likely to be claimed by the system
                // or by other apps, so the defaults deliberately avoid them.
                TestHarness.expect(modifiers & UInt32(cmdKey) == 0,
                                   "\(action.rawValue) avoids command (high conflict risk)")
            }
        }

        TestHarness.group("HotkeyBinding — round-trips through JSON") {
            for action in HotkeyAction.allCases {
                let binding = action.defaultBinding
                guard let data = try? JSONEncoder().encode(binding),
                      let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) else {
                    TestHarness.expect(false, "\(action.rawValue) encodes and decodes")
                    continue
                }
                TestHarness.equal(decoded, binding, "\(action.rawValue) survives a JSON round trip")
            }
        }

        TestHarness.group("PanelController — opacity presets") {
            let presets = PanelController.opacityPresets
            TestHarness.equal(presets.count, 5, "five opacity levels")
            TestHarness.equal(presets.first, 0.3, "the cycle starts at 30%")
            TestHarness.equal(presets.last, 1.0, "the cycle ends fully opaque")
            // `setOpacity` clamps to 0.2, so a preset below that would silently
            // land somewhere the menu never advertises.
            TestHarness.expect(presets.allSatisfy { $0 >= 0.2 && $0 <= 1.0 },
                               "every preset survives the setOpacity clamp")
            TestHarness.expect(zip(presets, presets.dropFirst()).allSatisfy { $0 < $1 },
                               "presets ascend, so the cycle never goes back a step")
        }
    }
}
