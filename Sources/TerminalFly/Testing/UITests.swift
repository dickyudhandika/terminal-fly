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

