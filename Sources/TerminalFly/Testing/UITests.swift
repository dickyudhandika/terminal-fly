import AppKit
import CoreGraphics
import Foundation
import SwiftTerm

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

            TestHarness.group("PositionManager — an oversize saved frame comes back on screen") {
                // Exactly the state the pre-fix build could leave behind: a frame
                // bigger than the display, saved as a custom position. Launch must
                // repair it, not restore a panel hanging off the screen.
                let defaults = UserDefaults.standard
                guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                else {
                    TestHarness.expect(false, "no screen available for the restore check")
                    return
                }
                let maximum = PanelGeometry.maximumSize(in: visible)
                defaults.set(NSStringFromRect(NSRect(x: visible.minX + 40,
                                                     y: visible.minY - 200,
                                                     width: maximum.width + 500,
                                                     height: maximum.height + 500)),
                             forKey: "panelFrame")
                defaults.set(true, forKey: "panelUsesCustomFrame")

                let restored = PanelController().panel.frame
                TestHarness.expect(restored.width <= maximum.width + 1
                                       && restored.height <= maximum.height + 1,
                                   "the restored frame is inside maximumSize (\(NSStringFromRect(restored)))")
                TestHarness.expect(PanelGeometry.isFullyVisible(restored, in: visible),
                                   "the restored frame is entirely on screen")
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

                // AppKit *does* enforce maxSize on `setFrame` (verified: an
                // oversize request comes back at maxSize), so lift the ceiling to
                // get an escaped frame at all. That isolation matters: it proves
                // the delegate's clamp, not AppKit's, is what pulls the panel in.
                controller.panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
                let origin = controller.panel.frame.origin
                let oversized = NSRect(x: origin.x, y: origin.y,
                                       width: maximum.width + 400,
                                       height: maximum.height + 400)

                controller.panel.setFrame(oversized, display: false)
                TestHarness.expect(controller.panel.frame.width > maximum.width,
                                   "the oversize frame was applied, so the clamp is what fixes it")

                // Post the notification a real mouse-up posts — AppKit dispatches
                // window notifications through the shared center, so this reaches
                // the delegate the same way a drag does.
                NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification,
                                                object: controller.panel)

                let corrected = controller.panel.frame
                TestHarness.equal(corrected.size, maximum,
                                  "windowDidEndLiveResize clamps the escape back to maximumSize")
                TestHarness.expect(PanelGeometry.isFullyVisible(corrected, in: visible),
                                   "the corrected frame is pulled back on screen too")
            }

            TestHarness.group("PanelController — growing from a mid-screen start stays on screen") {
                let controller = PanelController()
                guard let visible = (controller.panel.screen ?? NSScreen.main)?.visibleFrame
                else {
                    TestHarness.expect(false, "no screen available for the growth check")
                    return
                }
                // The reported shape: a small panel with its top edge low on the
                // screen, then ⌃⌥↓ held down. A size-only clamp still leaves it
                // hanging off the bottom.
                controller.panel.setFrame(NSRect(x: visible.minX + 40, y: visible.minY + 80,
                                                 width: 400, height: 150),
                                          display: false)
                for _ in 0..<100 { controller.grow() }
                let grown = controller.panel.frame
                TestHarness.expect(grown.height <= PanelGeometry.maximumSize(in: visible).height + 1,
                                   "repeated grow() stops at the height ceiling (got \(grown.height))")
                TestHarness.expect(PanelGeometry.isFullyVisible(grown, in: visible),
                                   "the panel is entirely on screen after growing from a low start (\(NSStringFromRect(grown)))")

                for _ in 0..<100 { controller.growWidth() }
                TestHarness.expect(PanelGeometry.isFullyVisible(controller.panel.frame, in: visible),
                                   "and still entirely on screen after growing wider (\(NSStringFromRect(controller.panel.frame)))")
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

            TestHarness.group("Panel — Cmd+V pastes into the shell") {
                let controller = PanelController()
                let panel = controller.panel
                panel.orderFrontRegardless()
                // The shell needs a moment before it reads its input.
                RunLoop.current.run(until: Date().addingTimeInterval(2.0))

                let marker = "TERMINALFLY_PASTE_OK"
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString("echo \(marker)\r", forType: .string)

                // Feed the event at the panel, which is where AppKit resolves a
                // key equivalent before any responder sees it. That is precisely
                // where Cmd+V was being lost: with no menu bar there is no
                // Edit > Paste item to claim it, and `NSApplication.sendEvent`
                // would find nothing to deliver it to. Going through the app
                // object instead makes the result depend on which window it
                // thinks is key, which in an unactivated accessory app is not
                // reliable enough to test with.
                TestHarness.expect(panel.performKeyEquivalent(with: commandV(in: panel)),
                                   "the panel claims Cmd+V")

                var pasted = false
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if screenText(of: controller.surface).contains(marker) {
                        pasted = true
                        break
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                }
                TestHarness.expect(pasted, "Cmd+V reached the shell (echoed \(marker))")

                // Cmd+C is deliberately left to the system: the terminal's own
                // copy would hijack the Services menu every other app expects.
                TestHarness.expect(
                    !panel.performKeyEquivalent(with: keyEvent("c", keyCode: 8, in: panel)),
                    "the panel leaves Cmd+C to the system"
                )
                panel.orderOut(nil)
            }

            TestHarness.group("Panel — drag selection reaches the clipboard") {
                let controller = PanelController()
                let panel = controller.panel
                panel.orderFrontRegardless()
                // The shell needs a moment before it paints its prompt.
                RunLoop.current.run(until: Date().addingTimeInterval(2.0))

                let surface = controller.surface
                let terminal = surface.getTerminal()
                // Deterministic drag path: with mouse reporting on, a drag is
                // forwarded to the shell as a mouse event instead of selecting.
                surface.allowMouseReporting = false
                // Clear what the live prompt painted, then seed the marker the
                // drag is supposed to pick up.
                let marker = "TERMINALFLY_DRAG_MARKER"
                surface.feed(text: "\u{1b}[2J\u{1b}[H")
                surface.feed(text: "\(marker)\r\n")
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))

                // Locate the marker in viewport coordinates (`getLine` is
                // scroll-invariant) and where it ends.
                var markerRow: Int?
                var markerEndCol = 0
                for row in 0..<terminal.rows {
                    guard let line = terminal.getLine(row: row) else { continue }
                    let text = line.translateToString(trimRight: true)
                    if let range = text.range(of: marker) {
                        markerRow = row
                        markerEndCol = text.distance(from: text.startIndex, to: range.upperBound)
                        break
                    }
                }
                // A missing marker would make every later assertion vacuous.
                guard let row = markerRow else {
                    TestHarness.expect(false, "seeded marker \(marker) is on screen")
                    panel.orderOut(nil)
                    return
                }

                // The arbitration fix is a property, not an event trace, and the
                // property has to be read through KVC: `mouseDownCanMoveWindow` is
                // declared `open` in SwiftTerm's `TerminalView`, i.e. outside this
                // module, and the app's `TerminalSurface` is internal, so a direct
                // member access here compiles only under `@testable`. KVC is the
                // one path available to a compiled-in test target.
                //
                // This is also the only observable that can carry the fix: a
                // synthetic `mouseDown` calls this view directly and never goes
                // through AppKit's window-drag arbitration, so no synthetic
                // sequence can reproduce the original dead-selection bug — the
                // drag below only proves the event path and the copy hook.
                TestHarness.expect(surface.value(forKey: "mouseDownCanMoveWindow") as? Bool == false,
                                   "the surface takes the click instead of dragging the window")

                // Derive cell geometry the way `processSizeChange` does: the
                // width is the view's own width over its column count, and the
                // height has no scroller term.
                let cellWidth = surface.bounds.width / CGFloat(max(1, terminal.cols))
                let cellHeight = surface.bounds.height / CGFloat(max(1, terminal.rows))
                func viewPoint(col: Int, row: Int) -> NSPoint {
                    NSPoint(x: (CGFloat(col) + 0.5) * cellWidth,
                            y: surface.bounds.height - (CGFloat(row) + 0.5) * cellHeight)
                }
                func mouseEvent(_ type: NSEvent.EventType, col: Int, row: Int,
                                number: Int) -> NSEvent {
                    // `calculateMouseHit` converts `locationInWindow`, so the
                    // event has to be built in window coordinates.
                    let windowPoint = surface.convert(viewPoint(col: col, row: row), to: nil)
                    return NSEvent.mouseEvent(with: type,
                                              location: windowPoint,
                                              modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber,
                                              context: nil,
                                              eventNumber: number,
                                              clickCount: 1,
                                              pressure: 0)!
                }

                // Overshoot the marker so cell-rounding drift cannot shorten
                // the selection to a prefix of it.
                let endCol = min(terminal.cols - 1, markerEndCol + 4)
                NSPasteboard.general.clearContents()

                surface.mouseDown(with: mouseEvent(.leftMouseDown, col: 0, row: row, number: 1))
                // The first drag anchors the selection, the second extends it.
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, col: 0, row: row, number: 2))
                surface.mouseDragged(with: mouseEvent(.leftMouseDragged, col: endCol, row: row, number: 3))
                surface.mouseUp(with: mouseEvent(.leftMouseUp, col: endCol, row: row, number: 4))

                TestHarness.expect(surface.selection.hasSelectionRange,
                                   "dragging selected a range")
                TestHarness.expect(surface.selection.getSelectedText().contains(marker),
                                   "the selection is the dragged marker text")
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                TestHarness.expect(copied.contains(marker),
                                   "releasing the drag copied the selection (\"\(copied.trimmingCharacters(in: .whitespaces))\")")

                // A bare click that dismisses the selection must not touch the
                // clipboard: `mouseDown` clears `selection.active`, so the copy
                // guard in `mouseUp` is what keeps this a no-op.
                NSPasteboard.general.clearContents()
                surface.mouseDown(with: mouseEvent(.leftMouseDown, col: 0, row: row, number: 5))
                surface.mouseUp(with: mouseEvent(.leftMouseUp, col: 0, row: row, number: 6))
                TestHarness.expect(NSPasteboard.general.string(forType: .string) == nil,
                                   "a click that only dismisses the selection copies nothing")

                panel.orderOut(nil)
            }

            TestHarness.group("Panel — content starts below the title bar") {
                let controller = PanelController()
                let panel = controller.panel
                panel.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))

                guard let contentView = panel.contentView,
                      let terminal = contentView.subviews.first else {
                    TestHarness.expect(false, "panel has a content view holding the terminal")
                    panel.orderOut(nil)
                    return
                }

                // The title bar is the top 24pt of a full-size content view. The
                // terminal must start below it, or its first line or two are
                // painted under the traffic-light buttons.
                let titleBarHeight: CGFloat = 24
                let terminalTopInWindow = contentView.convert(terminal.bounds, to: nil).maxY
                let contentTopInWindow = contentView.convert(contentView.bounds, to: nil).maxY
                TestHarness.expect(
                    abs((contentTopInWindow - terminalTopInWindow) - titleBarHeight) < 0.5,
                    "terminal top sits exactly one title bar below the content top"
                        + " (\(contentTopInWindow - terminalTopInWindow) vs \(titleBarHeight))"
                )
                // Not vacuous: a terminal that shrank to nothing would also
                // satisfy the check above.
                TestHarness.expect(
                    abs(terminal.frame.height - (contentView.bounds.height - titleBarHeight)) < 0.5,
                    "terminal fills the panel below the title bar (height \(terminal.frame.height))"
                )
                panel.orderOut(nil)
            }

            TestHarness.group("Panel — corners render at 8pt") {
                let controller = PanelController()
                let panel = controller.panel
                let control = self.controlPanel()
                control.orderFrontRegardless()
                panel.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))

                let configured = PanelController.cornerRadius
                TestHarness.equal(configured, 8, "the panel's corner radius is 8pt")

                // Compare against a window that kept AppKit's own corner. An
                // absolute number would mean little: the inset being measured is
                // not exactly the radius, it tracks it (measured 7pt for a
                // configured 8pt, 14pt for AppKit's default). The contrast is
                // unambiguous, and it is exactly what a content-view layer
                // radius fails to produce.
                guard let shipped = renderedCornerInset(of: panel),
                      let system = renderedCornerInset(of: control) else {
                    TestHarness.expect(false, "could not measure either rendered corner")
                    control.orderOut(nil)
                    panel.orderOut(nil)
                    return
                }
                TestHarness.expect(
                    shipped < system,
                    "the panel's corner is sharper than the system default"
                        + " (\(shipped)pt vs \(system)pt)"
                )
                TestHarness.expect(
                    abs(CGFloat(shipped) - configured) <= 2,
                    "the panel's rendered corner tracks the 8pt it asks for (\(shipped)pt)"
                )
                control.orderOut(nil)
                panel.orderOut(nil)
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

            TestHarness.group("PanelController — opacity cycle moves the real window") {
                let controller = PanelController()
                // 0.7 is on the preset list, so the press must move past it rather
                // than land on the level the panel already has.
                controller.setOpacity(0.7)
                controller.cycleOpacity()
                TestHarness.equal(controller.opacity, 0.85,
                                  "a press from a preset level steps past it")

                // Wrap: from the top preset the cycle returns to the bottom one.
                controller.setOpacity(1.0)
                controller.cycleOpacity()
                TestHarness.equal(controller.opacity, 0.3,
                                  "the cycle wraps from 100% back to 30%")

                // Off-list levels (the Appearance slider, the unfocused rule) get
                // the next preset up instead of an index-relative jump.
                controller.setOpacity(0.92)
                controller.cycleOpacity()
                TestHarness.equal(controller.opacity, 1.0,
                                  "an off-list level snaps up to the next preset")
            }

            TestHarness.group("PanelController — fullscreen and small-screen presets") {
                let controller = PanelController()
                let panel = controller.panel
                guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
                    TestHarness.expect(false, "no screen available for the preset check")
                    return
                }

                let original = NSRect(x: 200, y: 200, width: 620, height: 320)
                panel.setFrame(original, display: false)
                let originalFrame = panel.frame

                controller.toggleFullscreen()
                TestHarness.expect(controller.isFullscreen, "toggleFullscreen enters")
                TestHarness.equal(panel.frame, PanelGeometry.fullscreenFrame(in: visible),
                                  "the panel takes the fullscreen frame")
                TestHarness.expect(PanelGeometry.isFullyVisible(panel.frame, in: visible),
                                   "the fullscreen frame is entirely on screen")

                controller.toggleFullscreen()
                TestHarness.expect(!controller.isFullscreen, "toggleFullscreen exits")
                TestHarness.equal(panel.frame, originalFrame,
                                  "exiting fullscreen restores the previous frame")

                controller.toggleSmallScreen()
                TestHarness.expect(controller.isSmallScreen, "toggleSmallScreen enters")
                TestHarness.equal(panel.frame, PanelGeometry.smallFrame(in: visible),
                                  "the panel takes the small-screen frame")

                // Switching straight to fullscreen must not lose the user's real
                // frame: the small-screen frame is a preset, not a custom one.
                controller.toggleFullscreen()
                TestHarness.expect(!controller.isSmallScreen, "fullscreen clears small screen")
                TestHarness.equal(panel.frame, PanelGeometry.fullscreenFrame(in: visible),
                                  "switching presets applies the new frame directly")

                controller.toggleFullscreen()
                TestHarness.equal(panel.frame, originalFrame,
                                  "the frame from before the preset chain is restored")
            }

            harnessResult = TestHarness.finish()
        }

        return harnessResult
    }

    // MARK: - Helpers

    /// A panel that never had its corner radius touched — AppKit's own corner,
    /// for the test to contrast the shipped panel against.
    static func controlPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable,
                        .miniaturizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Match the panel's own rendering, so the only difference between the
        // two silhouettes is the corner.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.level = .floating
        panel.alphaValue = 0.92
        return panel
    }

    /// Measures where the window's visible body begins on its top row, in points.
    ///
    /// This is the corner as *rendered*, not as configured — the distinction the
    /// corner fix turns on, because setting the content view's layer radius
    /// leaves the window still rendering the system's corner. Only a pixel
    /// measurement catches that.
    ///
    /// The row is antialiased and the panel is translucent, so "first pixel
    /// bright enough to count as body" is threshold-dependent. Hence half the
    /// body alpha, which was measured to be stable: on this panel that crossing
    /// tracks the configured radius monotonically (4pt → 3, 8pt → 7, 12pt → 11,
    /// 16pt → 15) and separates AppKit's default (14) from an 8pt corner (7).
    ///
    /// `CGWindowListCreateImage` is deprecated in favour of ScreenCaptureKit,
    /// whose replacement is asynchronous and needs its own run loop, so it does
    /// not fit this synchronous harness. The deprecation is the price of
    /// asserting on the rendered result rather than on a property.
    static func renderedCornerInset(of window: NSWindow) -> Int? {
        guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              image.bitsPerPixel == 32
        else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        let rowStride = image.bytesPerRow
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[y * rowStride + x * bytesPerPixel + 3]) }

        let bodyAlpha = alpha(image.width / 2, image.height / 2)
        guard bodyAlpha > 0 else { return nil }
        let halfBody = bodyAlpha / 2

        for x in 0..<min(80, image.width) where alpha(x, 0) >= halfBody {
            return x
        }
        return nil
    }

    /// Reads the visible terminal screen out of the emulator.
    static func screenText(of surface: TerminalSurface) -> String {
        let terminal = surface.getTerminal()
        let end = Position(col: max(0, terminal.cols - 1), row: max(0, terminal.rows - 1))
        return terminal.getText(start: Position(col: 0, row: 0), end: end)
    }

    /// Builds a bare Cmd keystroke for `panel`, as AppKit would deliver it.
    static func keyEvent(_ character: String, keyCode: UInt16, in panel: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// A Cmd+V keystroke for `panel` (keyCode 9 is kVK_ANSI_V).
    static func commandV(in panel: NSWindow) -> NSEvent {
        keyEvent("v", keyCode: 9, in: panel)
    }
}

