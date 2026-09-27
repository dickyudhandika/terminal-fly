import CoreGraphics

/// Pure geometry for parking the panel in a screen corner.
///
/// Deliberately free of AppKit so it can be unit-tested headlessly (see
/// `GeometryTests`). `PositionManager` is the thin AppKit shell that feeds this
/// real `NSScreen.visibleFrame` values and applies the result to the `NSPanel`.
///
/// `visibleFrame` already excludes the menu bar and the Dock, so the margin here
/// is pure breathing room, not a menu-bar allowance.
struct PanelGeometry {
    /// Gap between the panel edge and the edge of the screen's visible area.
    static let margin: CGFloat = 24

    /// Smallest height the panel may be shrunk to. Below this the terminal has
    /// almost no rows and the prompt is unusable.
    static let minimumHeight: CGFloat = 120

    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var label: String {
            switch self {
            case .topLeft: return "Top-Left"
            case .topRight: return "Top-Right"
            case .bottomLeft: return "Bottom-Left"
            case .bottomRight: return "Bottom-Right"
            }
        }

        /// The next corner in the cycle used by the ⌃⌥C hotkey.
        var next: Corner {
            let all = Corner.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    /// Origin for `size` parked in `corner` inside `visibleFrame`.
    ///
    /// Coordinates are the standard Cocoa bottom-left origin system: `maxY` is
    /// the top of the screen, `minY` the bottom.
    static func origin(for corner: Corner, size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .topRight:
            return CGPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .bottomLeft:
            return CGPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.minY + margin)
        case .bottomRight:
            return CGPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.minY + margin)
        }
    }

    static func frame(for corner: Corner, size: CGSize, in visibleFrame: CGRect) -> CGRect {
        CGRect(origin: origin(for: corner, size: size, in: visibleFrame), size: size)
    }

    /// Grows or shrinks the height while keeping the top edge fixed, so a
    /// top-anchored panel does not creep down the screen as it grows.
    static func resized(_ frame: CGRect, byHeightDelta delta: CGFloat, in visibleFrame: CGRect) -> CGRect {
        let maximum = visibleFrame.height - margin * 2
        let clamped = max(minimumHeight, min(frame.height + delta, maximum))
        var result = frame
        result.origin.y -= (clamped - frame.height)
        result.size.height = clamped
        return result
    }

    /// Whether `frame` still looks like it is parked in a corner rather than
    /// dragged somewhere free-floating. Used at launch to decide whether a saved
    /// corner-preset frame is worth restoring.
    static func isCornerLike(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        let nearLeft = abs(frame.minX - (visibleFrame.minX + margin)) < tolerance
        let nearRight = abs(frame.maxX - (visibleFrame.maxX - margin)) < tolerance
        let nearTop = abs(frame.maxY - (visibleFrame.maxY - margin)) < tolerance
        let nearBottom = abs(frame.minY - (visibleFrame.minY + margin)) < tolerance
        return (nearLeft || nearRight) && (nearTop || nearBottom)
    }

    /// Whether enough of the frame is on screen to be usable. A saved frame can
    /// reference a display that no longer exists; restoring it blindly leaves
    /// the panel off-screen and the app looks broken.
    static func isUsable(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        visibleFrame.intersection(frame).width > 80
    }

    /// Whether `frame` is fully inside the visible area.
    static func isFullyVisible(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        visibleFrame.contains(frame)
    }
}

/// Corner preset. Kept as a top-level enum (rather than nesting it) so
/// persistence code can refer to `PanelCorner(rawValue:)` directly.
typealias PanelCorner = PanelGeometry.Corner
