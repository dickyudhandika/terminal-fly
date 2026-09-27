import AppKit
import SwiftUI

/// Menu bar item with quick actions.
struct MenuBarMenu: View {
    @ObservedObject var store: PreferencesStore
    let controller: PanelController
    var onOpenSettings: () -> Void
    var onRestartShell: () -> Void
    var onQuit: () -> Void

    /// herdr section. Optional so the menu still renders on a machine without it.
    var herdrPanes: [HerdrProtocol.Pane] = []
    var isHerdrMode: Bool = false
    var onEnterHerdr: ((String?) -> Void)?
    var onExitHerdr: (() -> Void)?

    @State private var revision = 0

    var body: some View {
        Toggle("Show Panel", isOn: Binding(
            get: { controller.isVisible },
            set: { $0 ? controller.show() : controller.hide() }
        ))
        .keyboardShortcut("p", modifiers: [.control, .option])

        Divider()

        Menu("Position") {
            ForEach(PanelCorner.allCases, id: \.self) { corner in
                Button {
                    controller.positions.move(to: corner)
                    revision += 1
                } label: {
                    // A checkmark for the active preset. `Menu` does not render
                    // a picker checkmark reliably for plain Buttons, so the
                    // marker is in the label.
                    Text(corner == controller.positions.lastCorner
                         ? "✓ \(corner.label)"
                         : "   \(corner.label)")
                }
            }
            Divider()
            Button("Cycle corner") { controller.cycleCorner(); revision += 1 }
        }

        Menu("Opacity: \(Int(store.opacity * 100))%") {
            ForEach([0.3, 0.5, 0.7, 0.8, 0.9, 1.0], id: \.self) { value in
                Button {
                    store.opacity = value
                    controller.setOpacity(CGFloat(value))
                    revision += 1
                } label: {
                    Text(abs(store.opacity - value) < 0.001
                         ? "✓ \(Int(value * 100))%"
                         : "   \(Int(value * 100))%")
                }
            }
        }

        Button("Grow height") { controller.grow() }
        Button("Shrink height") { controller.shrink() }
        Button("Grow width") { controller.growWidth() }
        Button("Shrink width") { controller.shrinkWidth() }

        Divider()

        Button("New Shell") { onRestartShell() }

        Divider()

        if let onEnterHerdr {
            if isHerdrMode {
                Button("Leave herdr mode") { onExitHerdr?() }
            } else if herdrPanes.isEmpty {
                Text("herdr: no panes")
            } else {
                Menu("Follow herdr pane") {
                    ForEach(herdrPanes) { pane in
                        Button(pane.displayName) { onEnterHerdr(pane.paneID) }
                    }
                }
            }
            Divider()
        }

        Button("Settings…") { onOpenSettings() }
        Button("Quit Terminal Fly") { onQuit() }
    }
}

/// SwiftUI needs a stable id for `ForEach`; the pane id is exactly that.
extension HerdrProtocol.Pane: Identifiable {
    public var id: String { paneID }
}

/// Owns the `NSStatusItem` and its SwiftUI menu.
///
/// The status item itself is AppKit (`NSStatusBar`); the menu content is a
/// SwiftUI view hosted in an `NSHostingView`, so the panel's opacity and
/// visibility state can drive the menu directly instead of being duplicated in
/// a hand-built `NSMenu`.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(content: some View) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "Terminal Fly"
            )
            button.image?.isTemplate = true
            button.toolTip = "Terminal Fly"
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content)
    }

    /// Re-render the menu content (checkmarks, opacity label) after an action.
    func updateContent(_ content: some View) {
        popover.contentViewController = NSHostingController(rootView: content)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Showing a popover from an accessory app does not activate it by
            // default, which leaves the controls unclickable.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
