import CoreGraphics
import Foundation

/// Pure-logic tests, run via `TerminalFly --test`.
enum GeometryTests {
    /// A 1920x1080 screen with a 25pt menu bar and a 70pt Dock at the bottom —
    /// roughly what you get on a real display.
    private static let screen = CGRect(x: 0, y: 70, width: 1920, height: 985)
    private static let size = CGSize(width: 620, height: 320)

    static func run() {
        TestHarness.group("PanelGeometry — corner presets") {
            let topLeft = PanelGeometry.frame(for: .topLeft, size: size, in: screen)
            TestHarness.equal(topLeft.minX, 24, "topLeft hugs left edge + margin")
            TestHarness.equal(topLeft.maxY, screen.maxY - 24, "topLeft hugs top edge - margin")

            let topRight = PanelGeometry.frame(for: .topRight, size: size, in: screen)
            TestHarness.equal(topRight.maxX, screen.maxX - 24, "topRight hugs right edge - margin")
            TestHarness.equal(topRight.maxY, screen.maxY - 24, "topRight sits at the top")

            let bottomLeft = PanelGeometry.frame(for: .bottomLeft, size: size, in: screen)
            TestHarness.equal(bottomLeft.minX, 24, "bottomLeft hugs left edge")
            TestHarness.equal(bottomLeft.minY, screen.minY + 24, "bottomLeft clears the Dock")

            let bottomRight = PanelGeometry.frame(for: .bottomRight, size: size, in: screen)
            TestHarness.equal(bottomRight.maxX, screen.maxX - 24, "bottomRight hugs right edge")
            TestHarness.equal(bottomRight.minY, screen.minY + 24, "bottomRight clears the Dock")
            TestHarness.equal(bottomRight.size, size, "preset does not change the panel size")
        }

        TestHarness.group("PanelGeometry — every preset stays fully on screen") {
            for corner in PanelCorner.allCases {
                let frame = PanelGeometry.frame(for: corner, size: size, in: screen)
                TestHarness.expect(
                    PanelGeometry.isFullyVisible(frame, in: screen),
                    "\(corner.label) is fully inside the visible frame"
                )
            }
        }

        TestHarness.group("PanelGeometry — corner cycling") {
            TestHarness.equal(PanelCorner.bottomRight.next, .topLeft, "bottomRight wraps to topLeft")
            TestHarness.equal(PanelCorner.topLeft.next, .topRight, "topLeft advances to topRight")
            TestHarness.equal(PanelCorner.topRight.next, .bottomLeft, "topRight advances to bottomLeft")
            TestHarness.equal(PanelCorner.bottomLeft.next, .bottomRight, "bottomLeft advances to bottomRight")

            // Cycling four times must return to the start.
            var corner = PanelCorner.topLeft
            for _ in 0..<4 { corner = corner.next }
            TestHarness.equal(corner, .topLeft, "four cycles returns to the starting corner")
        }

        TestHarness.group("PanelGeometry — height resize") {
            let base = PanelGeometry.frame(for: .topRight, size: size, in: screen)

            let grown = PanelGeometry.resized(base, byHeightDelta: 100, in: screen)
            TestHarness.equal(grown.height, 420, "grows by the requested delta")
            TestHarness.equal(grown.maxY, base.maxY, "top edge stays pinned while growing")
            TestHarness.equal(grown.maxX, base.maxX, "right edge stays pinned while growing")

            let shrunk = PanelGeometry.resized(base, byHeightDelta: -100, in: screen)
            TestHarness.equal(shrunk.height, 220, "shrinks by the requested delta")
            TestHarness.equal(shrunk.minY, base.minY + 100, "shrinking pulls the bottom edge up")

            let tiny = PanelGeometry.resized(base, byHeightDelta: -10_000, in: screen)
            TestHarness.equal(tiny.height, PanelGeometry.minimumHeight,
                              "will not shrink below the usable minimum")

            let huge = PanelGeometry.resized(base, byHeightDelta: 10_000, in: screen)
            TestHarness.expect(huge.height <= screen.height, "will not grow past the screen")
            TestHarness.expect(PanelGeometry.isFullyVisible(huge, in: screen),
                               "a maximised panel is still fully on screen")
        }

        TestHarness.group("PanelGeometry — saved-frame validation") {
            let corner = PanelGeometry.frame(for: .bottomRight, size: size, in: screen)
            TestHarness.expect(PanelGeometry.isCornerLike(corner, in: screen),
                               "a preset frame reads as corner-like")
            TestHarness.expect(PanelGeometry.isUsable(corner, in: screen),
                               "a preset frame is usable")

            let floating = CGRect(x: 700, y: 400, width: 620, height: 320)
            TestHarness.expect(!PanelGeometry.isCornerLike(floating, in: screen),
                               "a dragged frame is NOT corner-like")
            TestHarness.expect(PanelGeometry.isUsable(floating, in: screen),
                               "a dragged frame is still usable")

            // Simulates an unplugged external display: the saved frame lives far
            // off to the right of the remaining screen.
            let stranded = CGRect(x: 3000, y: 500, width: 620, height: 320)
            TestHarness.expect(!PanelGeometry.isUsable(stranded, in: screen),
                               "a frame on a vanished display is rejected")

            // A frame hanging half off the right edge: some is visible, so we
            // accept it rather than snapping the user's deliberate position.
            let overhanging = CGRect(x: 1500, y: 400, width: 620, height: 320)
            TestHarness.expect(PanelGeometry.isUsable(overhanging, in: screen),
                               "a partially on-screen frame is still accepted")
            TestHarness.expect(!PanelGeometry.isFullyVisible(overhanging, in: screen),
                               "…but it is not fully visible")
        }
    }
}
