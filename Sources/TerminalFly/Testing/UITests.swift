import AppKit
import CoreGraphics
import Foundation

/// End-to-end checks that need a real window server, run via
/// `TerminalFly --uitest`.
///
/// These build the real `PanelController` and assert on the real `NSPanel`.
/// They deliberately do NOT need a human: they read the panel's `level` and
/// `alphaValue` properties directly, and use `CGWindowListCopyWindowInfo` to
/// confirm the window actually reached the window server at the floating level.
enum UITests {
    static func run() -> Int32 {
        var harnessResult: Int32 = 0

        MainActor.assumeIsolated {
            // These groups drive the real panel, and the panel persists its frame
            // as it moves. Snapshot the user's own settings first, so a `--uitest`
            // run cannot leave their terminal parked at whatever size the last
            // clamp loop happened to stop at.
            let defaults = UserDefaults.standard
            let persistedKeys = ["panelFrame", "panelCorner", "panelUsesCustomFrame"]
            let snapshot = Dictionary(uniqueKeysWithValues: persistedKeys.map {
                ($0, defaults.object(forKey: $0))
            })
            defer {
                for (key, value) in snapshot {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }

            TestHarness.group("PanelController — floating window configuration") {
                let controller = PanelController()

                TestHarness.equal(controller.panel.level, .floating,
                                  "panel is at the floating window level")
                TestHarness.expect(controller.panel.isFloatingPanel,
                                   "panel reports itself as a floating panel")
                TestHarness.expect(!controller.panel.hidesOnDeactivate,
                                   "panel stays visible when another app takes focus")
                TestHarness.expect(controller.panel.collectionBehavior.contains(.canJoinAllSpaces),
                                   "panel follows across Spaces")
                TestHarness.expect(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary),
                                   "panel can float over a full-screen app")
                TestHarness.expect(controller.panel.styleMask.contains(.nonactivatingPanel),
                                   "panel does not activate the app when clicked")
                TestHarness.expect(controller.panel.styleMask.contains(.resizable),
                                   "panel is resizable (unlike kitty's locked overlay)")
                TestHarness.expect(controller.panel.isMovableByWindowBackground,
                                   "panel can be dragged by its background")
                TestHarness.expect(controller.panel.canBecomeKey,
                                   "panel accepts keyboard input when clicked")
                TestHarness.expect(!controller.panel.canBecomeMain,
                                   "panel never becomes the app's main window")
            }

            TestHarness.group("PanelController — visibility toggle") {
                let controller = PanelController()
                controller.show()
                TestHarness.expect(controller.isVisible, "show() makes the panel visible")
                controller.hide()
                TestHarness.expect(!controller.isVisible, "hide() hides the panel")
                controller.toggle()
                TestHarness.expect(controller.isVisible, "toggle() shows a hidden panel")
                controller.toggle()
                TestHarness.expect(!controller.isVisible, "toggle() hides a visible panel")
            }

            TestHarness.group("PanelController — opacity clamping") {
                let controller = PanelController()
                controller.setOpacity(0.5)
                TestHarness.equal(controller.opacity, 0.5, "opacity is applied verbatim")
                controller.setOpacity(5.0)
                TestHarness.equal(controller.opacity, 1.0, "opacity clamps to 1.0")
                controller.setOpacity(-3.0)
                TestHarness.equal(controller.opacity, 0.2, "opacity clamps to the 0.2 floor")
            }

            TestHarness.group("PanelController — corner presets move the real window") {
                let controller = PanelController()
                guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                    TestHarness.expect(false, "no screen available")
                    return
                }
                let visible = screen.visibleFrame

                controller.positions.move(to: .bottomRight, on: screen)
                let bottomRight = controller.panel.frame
                TestHarness.expect(PanelGeometry.isFullyVisible(bottomRight, in: visible),
                                   "bottomRight preset is fully on screen")
                TestHarness.expect(abs(bottomRight.maxX - (visible.maxX - PanelGeometry.margin)) < 1,
                                   "bottomRight frame hugs the right edge")

                controller.positions.move(to: .topLeft, on: screen)
                let topLeft = controller.panel.frame
                TestHarness.expect(PanelGeometry.isFullyVisible(topLeft, in: visible),
                                   "topLeft preset is fully on screen")
                TestHarness.expect(abs(topLeft.minX - (visible.minX + PanelGeometry.margin)) < 1,
                                   "topLeft frame hugs the left edge")

                TestHarness.equal(controller.positions.lastCorner, .topLeft,
                                  "last corner is remembered")
            }

            TestHarness.group("PanelController — cycling through the real window") {
                let controller = PanelController()
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
                controller.positions.move(to: .bottomRight, on: screen)

                var seen: [PanelCorner] = []
                for _ in 0..<4 {
                    seen.append(controller.cycleCorner())
                }
                TestHarness.equal(seen.count, 4, "four cycles produce four corners")
                TestHarness.equal(Set(seen.map(\.rawValue)).count, 4,
                                  "four cycles visit four distinct corners")
                TestHarness.equal(controller.positions.lastCorner, .bottomRight,
                                  "cycling four times returns to the start")
            }

            TestHarness.group("PanelController — height hotkeys change the real window") {
                let controller = PanelController()
                // A known starting size, so the delta assertions hold whatever the
                // persisted frame happens to be (see the width group below).
                controller.panel.setFrame(NSRect(x: 100, y: 100, width: 620, height: 320),
                                          display: false)
                controller.positions.move(to: .topRight)
                let before = controller.panel.frame

                controller.grow()
                let grown = controller.panel.frame
                TestHarness.expect(grown.height > before.height, "grow() increases height")
                TestHarness.expect(abs(grown.maxY - before.maxY) < 1,
                                   "grow() keeps the top edge pinned")

                controller.shrink()
                controller.shrink()
                let shrunk = controller.panel.frame
                TestHarness.expect(shrunk.height < before.height, "shrink() reduces height")
            }

            TestHarness.group("PanelController — resize limits come from the screen") {
                let controller = PanelController()
                let panel = controller.panel
                guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
                    TestHarness.expect(false, "no screen available for the size-limits check")
                    return
                }
                let maximum = PanelGeometry.maximumSize(in: visible)

                // AppKit refuses to drag a window past maxSize / below minSize,
                // so these four numbers are what the mouse is actually bounded by.
                TestHarness.equal(panel.maxSize.width, maximum.width,
                                  "maxSize.width is the visible width minus two margins")
                TestHarness.equal(panel.maxSize.height, maximum.height,
                                  "maxSize.height is the visible height minus two margins")
                TestHarness.equal(panel.minSize.width, PanelGeometry.minimumWidth,
                                  "minSize.width is the usable minimum width")
                TestHarness.equal(panel.minSize.height, PanelGeometry.minimumHeight,
                                  "minSize.height is the usable minimum height")
            }

            TestHarness.group("PanelController — width hotkeys change the real window") {
                let controller = PanelController()
                // Start from a known size: whatever a previous run persisted may
                // already sit on one of the clamps, which would make the deltas
                // meaningless.
                controller.panel.setFrame(NSRect(x: 100, y: 100, width: 620, height: 320),
                                          display: false)
                controller.positions.move(to: .topRight)
                let before = controller.panel.frame

                controller.growWidth()
                let grown = controller.panel.frame
                TestHarness.expect(grown.width > before.width, "growWidth() increases width")
                TestHarness.expect(abs(grown.maxX - before.maxX) < 1,
                                   "growWidth() keeps the right edge pinned")

                controller.shrinkWidth()
                TestHarness.expect(controller.panel.frame.width < grown.width,
                                   "shrinkWidth() reduces width")
            }

            TestHarness.group("PanelController — width hotkeys stop at the screen edge") {
                let controller = PanelController()
                controller.positions.move(to: .topRight)
                guard let visible = (controller.panel.screen ?? NSScreen.main)?.visibleFrame
                else {
                    TestHarness.expect(false, "no screen available for the width clamp check")
                    return
                }
                let maximum = PanelGeometry.maximumSize(in: visible)

                // Far more presses than it takes to cross the whole display.
                for _ in 0..<80 { controller.growWidth() }
                let grown = controller.panel.frame
                TestHarness.expect(grown.width <= maximum.width + 1,
                                   "growing forever stops at maxSize (got \(grown.width), max \(maximum.width))")
                TestHarness.expect(PanelGeometry.isFullyVisible(grown, in: visible),
                                   "a fully grown panel is still entirely on screen")

                for _ in 0..<80 { controller.shrinkWidth() }
                TestHarness.expect(controller.panel.frame.width >= PanelGeometry.minimumWidth,
                                   "shrinking forever stops at minimumWidth")
            }

            TestHarness.group("PanelDelegate — a resize that escapes the limits is pulled back") {
                let controller = PanelController()
                guard let visible = (controller.panel.screen ?? NSScreen.main)?.visibleFrame
                else {
                    TestHarness.expect(false, "no screen available for the clamp check")
                    return
                }
                let maximum = PanelGeometry.maximumSize(in: visible)
                let limits = controller.panel.maxSize
                defer { controller.panel.maxSize = limits }

                // Take AppKit's own constraint away so the oversize frame can
                // exist at all: this isolates the delegate's safety net, which is
                // what catches a drag whose ceiling moved mid-gesture.
                controller.panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
                let origin = controller.panel.frame.origin
                let oversized = NSRect(x: origin.x, y: origin.y,
                                       width: maximum.width + 400,
                                       height: maximum.height + 400)

                controller.panel.setFrame(oversized, display: false)
                TestHarness.expect(controller.panel.frame.width > maximum.width,
                                   "the oversize frame was applied, so the clamp is what fixes it")

                // Fire the delegate exactly as AppKit does when a mouse-up ends a
                // live resize, rather than trusting AppKit to synthesise a drag.
                let notification = Notification(name: NSWindow.didEndLiveResizeNotification,
                                                object: controller.panel)
                (controller.panel.delegate as? PanelDelegate)?.windowDidEndLiveResize(notification)

                let corrected = controller.panel.frame
                TestHarness.equal(corrected.size, maximum,
                                  "windowDidEndLiveResize clamps the escape back to maximumSize")
            }

            TestHarness.group("PreferencesStore — live appearance application") {
                let store = PreferencesStore.shared
                let controller = PanelController()

                store.opacity = 0.55
                controller.setOpacity(CGFloat(store.opacity))
                TestHarness.expect(abs(controller.panel.alphaValue - 0.55) < 0.001,
                                   "panel alpha follows the opacity preference")

                let font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
                controller.surface.applyFont(font)
                TestHarness.equal(controller.surface.font.pointSize, 17,
                                  "terminal font size updates live")

                store.theme = .solarizedDark
                let colors = store.theme.colors
                controller.surface.applyColors(background: colors.background,
                                               foreground: colors.foreground,
                                               caret: colors.caret,
                                               selection: colors.selection)
                TestHarness.equal(controller.surface.nativeBackgroundColor, colors.background,
                                  "terminal background follows the theme")
                TestHarness.equal(controller.surface.nativeForegroundColor, colors.foreground,
                                  "terminal foreground follows the theme")

                // Restore so the tests do not leave the user's real prefs changed.
                store.opacity = 0.92
                store.theme = .dark
            }

            TestHarness.group("Window server — panel really reaches the floating level") {
                let controller = PanelController()
                controller.show()
                // Give the window server a moment to place the window.
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))

                let windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                ) as? [[String: Any]] ?? []

                let mine = windows.filter {
                    ($0[kCGWindowOwnerName as String] as? String) == "Terminal Fly"
                }
                TestHarness.expect(!mine.isEmpty, "Terminal Fly has an on-screen window")

                if let window = mine.first {
                    // 3 == kCGFloatingWindowLevel, what NSWindow.level == .floating maps to.
                    let level = window[kCGWindowLayer as String] as? Int ?? -1
                    TestHarness.equal(level, 3, "window server reports the floating level")
                    TestHarness.expect(
                        (window[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                        "window is on screen"
                    )
                }
                controller.hide()
            }

            harnessResult = TestHarness.finish()
        }

        return harnessResult
    }
}

