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
            TestHarness.equal(huge.height, screen.height - PanelGeometry.margin * 2,
                              "will not grow past the screen")
            TestHarness.expect(PanelGeometry.isFullyVisible(huge, in: screen),
                               "a maximised panel is still fully on screen")
        }

        TestHarness.group("PanelGeometry — width resize") {
            let base = PanelGeometry.frame(for: .topRight, size: size, in: screen)

            let grown = PanelGeometry.resizedWidth(base, byWidthDelta: 100, in: screen)
            TestHarness.equal(grown.width, 720, "grows width by the requested delta")
            TestHarness.equal(grown.maxX, base.maxX, "right edge stays pinned while growing")

            let shrunk = PanelGeometry.resizedWidth(base, byWidthDelta: -100, in: screen)
            TestHarness.equal(shrunk.width, 520, "shrinks width by the requested delta")
            TestHarness.equal(shrunk.minX, base.minX + 100, "shrinking pulls the left edge in")

            let tiny = PanelGeometry.resizedWidth(base, byWidthDelta: -10_000, in: screen)
            TestHarness.equal(tiny.width, PanelGeometry.minimumWidth,
                              "will not shrink below the usable minimum")

            let huge = PanelGeometry.resizedWidth(base, byWidthDelta: 10_000, in: screen)
            TestHarness.equal(huge.width, screen.width - PanelGeometry.margin * 2,
                              "max width is exactly visibleFrame.width minus two margins")
            TestHarness.expect(PanelGeometry.isFullyVisible(huge, in: screen),
                               "a max-width panel is still fully on screen")
        }

        TestHarness.group("PanelGeometry — width resize keeps a left-parked panel left") {
            let base = PanelGeometry.frame(for: .topLeft, size: size, in: screen)
            let huge = PanelGeometry.resizedWidth(base, byWidthDelta: 10_000, in: screen)
            TestHarness.equal(huge.minX, base.minX,
                              "a left-anchored panel grows rightwards, not off the left edge")
            TestHarness.expect(PanelGeometry.isFullyVisible(huge, in: screen),
                               "a max-width left panel is still fully on screen")
        }

        TestHarness.group("PanelGeometry — maximumSize helper") {
            let maximum = PanelGeometry.maximumSize(in: screen)
            TestHarness.equal(maximum.width, screen.width - PanelGeometry.margin * 2,
                              "max width is visible width minus two margins")
            TestHarness.equal(maximum.height, screen.height - PanelGeometry.margin * 2,
                              "max height is visible height minus two margins")
        }

        TestHarness.group("PanelGeometry — size clamp safety net") {
            // Too big on both axes: back down to the ceiling, and pulled back
            // inside the screen (its right edge cannot stay at x=4100).
            let oversized = CGRect(x: 100, y: 100, width: 4000, height: 4000)
            let shrunkToMax = PanelGeometry.clamped(oversized, in: screen)
            TestHarness.equal(shrunkToMax.size, PanelGeometry.maximumSize(in: screen),
                              "an oversized frame clamps to maximumSize")
            TestHarness.expect(PanelGeometry.isFullyVisible(shrunkToMax, in: screen),
                               "an oversized frame ends up entirely on screen")

            // Too small on both axes: back up to the usable minimum.
            let undersized = CGRect(x: 100, y: 100, width: 10, height: 10)
            TestHarness.equal(PanelGeometry.clamped(undersized, in: screen).size,
                              CGSize(width: PanelGeometry.minimumWidth,
                                     height: PanelGeometry.minimumHeight),
                              "an undersized frame clamps to the minima")

            // A frame that already fits must survive the round trip verbatim.
            let fitting = PanelGeometry.frame(for: .bottomRight, size: size, in: screen)
            TestHarness.equal(PanelGeometry.clamped(fitting, in: screen), fitting,
                              "a frame inside the limits is returned unchanged")
        }

        TestHarness.group("PanelGeometry — an off-screen position is pulled back") {
            let hangingRight = CGRect(x: 1800, y: 400, width: 620, height: 320)
            let fixedRight = PanelGeometry.clamped(hangingRight, in: screen)
            TestHarness.equal(fixedRight.size, hangingRight.size,
                              "a legal size is not touched by the position clamp")
            TestHarness.equal(fixedRight.maxX, screen.maxX,
                              "a frame hanging off the right is pulled to the edge")

            let hangingBottom = CGRect(x: 400, y: -100, width: 620, height: 320)
            TestHarness.equal(PanelGeometry.clamped(hangingBottom, in: screen).minY, screen.minY,
                              "a frame hanging off the bottom is lifted back on screen")

            let hangingTop = CGRect(x: 400, y: 900, width: 620, height: 320)
            TestHarness.equal(PanelGeometry.clamped(hangingTop, in: screen).maxY, screen.maxY,
                              "a frame poking above the visible area is pushed back under it")
        }

        TestHarness.group("PanelGeometry — growth from a mid-screen start stays on screen") {
            // The reported bug: a small panel whose top edge sits low on the
            // screen. Height grows from a pinned top edge, so without a position
            // correction a legal 937pt panel still hangs off the bottom.
            let low = CGRect(x: 24, y: 200, width: 620, height: 160)
            let grown = PanelGeometry.resized(low, byHeightDelta: 10_000, in: screen)
            TestHarness.equal(grown.height, screen.height - PanelGeometry.margin * 2,
                              "the height still caps at the maximum")
            TestHarness.equal(grown.minY, screen.minY,
                              "the bottom edge is pulled back inside the visible frame")
            TestHarness.expect(PanelGeometry.isFullyVisible(grown, in: screen),
                               "growing from any starting position ends fully on screen")

            // Same on the width axis: a free-floating panel grown past the edge.
            let right = CGRect(x: 1500, y: 200, width: 620, height: 160)
            let widened = PanelGeometry.resizedWidth(right, byWidthDelta: 10_000, in: screen)
            TestHarness.equal(widened.width, screen.width - PanelGeometry.margin * 2,
                              "the width still caps at the maximum")
            TestHarness.equal(widened.maxX, screen.maxX,
                              "the right edge is pulled back inside the visible frame")
            TestHarness.expect(PanelGeometry.isFullyVisible(widened, in: screen),
                               "widening from any starting position ends fully on screen")
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
