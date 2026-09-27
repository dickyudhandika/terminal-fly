# Fix: Panel resize has no screen-bounds limit

## Goal
Clamp panel width and height to the current screen's visible frame so the panel cannot be resized (by hotkey or mouse drag) beyond the monitor edges.

## Current context / assumptions
- Project: `~/Documents/terminal-fly/` — Swift macOS app, commit `30bd9cd`
- Build: `bash scripts/build.sh release` → binary at `build/release/TerminalFly`
- Tests: `build/release/TerminalFly --test` (headless logic), `--uitest` (window server)
- Verify: `bash scripts/verify.sh release` runs all checks
- **No Xcode on this machine** — `swiftc` direct compile via `scripts/build.sh`

### Root cause (two separate gaps)

**Gap 1 — Mouse drag resize is completely unbounded.**
`PanelController.swift` line 35 creates the panel with `.resizable` style mask but never sets `panel.maxSize`. AppKit default is "no maximum." The user can drag the panel edge past the screen boundary, and the overflow is cropped/invisible. `PanelDelegate.swift` only saves the frame in `windowDidEndLiveResize` — it never clamps.

**Gap 2 — Hotkey height grow is clamped but width is not handled.**
`PanelGeometry.resized()` (line 66) clamps height to `visibleFrame.height - margin * 2`. This works for height. But there is no width resize hotkey and no width clamp function. The user asked for "max width based on monitor resolution" — currently width can only change via mouse drag, which has no limit (Gap 1).

### Key files
- `Sources/TerminalFly/Window/PanelGeometry.swift` — pure geometry, clamping logic
- `Sources/TerminalFly/Window/PanelController.swift` — panel creation, `grow()`/`shrink()`
- `Sources/TerminalFly/Window/PositionManager.swift` — `adjustHeight(by:)`, applies frames
- `Sources/TerminalFly/Window/PanelDelegate.swift` — `NSWindowDelegate`, frame persistence
- `Sources/TerminalFly/Testing/GeometryTests.swift` — headless geometry tests
- `Sources/TerminalFly/Testing/UITests.swift` — window-server UI tests

## Architecture / proposed approach
Set `panel.maxSize` and `panel.minSize` at creation and on screen change so AppKit itself enforces bounds during mouse drag. Add a `PanelGeometry.resizedWidth()` function mirroring the existing height clamp. Update `windowDidEndLiveResize` to clamp-and-correct if a drag somehow exceeded bounds (belt + suspenders). Add unit tests for width clamping and for the exact max-height value (current test only asserts `<= screen.height`, not the precise clamp).

## Step-by-step tasks

### Step 1: Add `maximumSize` and `minimumSize` to PanelGeometry
**File:** `Sources/TerminalFly/Window/PanelGeometry.swift`

Add two static computed properties after `minimumHeight` (line 17):

```swift
/// Smallest width the panel may be shrunk to. Below this the terminal
/// has too few columns to render a prompt legibly.
static let minimumWidth: CGFloat = 300

/// Maximum panel size within `visibleFrame`, leaving `margin` on all sides.
/// Used both for AppKit's `maxSize` (mouse drag constraint) and for the
/// resize clamp functions.
static func maximumSize(in visibleFrame: CGRect) -> CGSize {
    CGSize(width: visibleFrame.width - margin * 2,
           height: visibleFrame.height - margin * 2)
}
```

**Verification:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
# Expected: ==> built .../build/TerminalFly.app
```

### Step 2: Set `maxSize` and `minSize` on the panel at creation
**File:** `Sources/TerminalFly/Window/PanelController.swift`

After line 68 (`panel.backgroundColor = ...`), add:

```swift
// Constrain mouse-drag resize to the visible screen area.
// Updated on screen change in `updateSizeLimits()`.
updateSizeLimits()
```

Add a new method at the end of the class (before the closing `}`):

```swift
/// Sets `panel.maxSize` and `panel.minSize` from the current screen's
/// visible frame. Called at launch and whenever the panel changes screen.
func updateSizeLimits() {
    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let max = PanelGeometry.maximumSize(in: visible)
    panel.maxSize = NSSize(width: max.width, height: max.height)
    panel.minSize = NSSize(width: PanelGeometry.minimumWidth,
                           height: PanelGeometry.minimumHeight)
}
```

**Verification:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
# Expected: ==> built .../build/TerminalFly.app
```

### Step 3: Call `updateSizeLimits()` on screen change
**File:** `Sources/TerminalFly/Window/PositionManager.swift`

In the `move(to:)` method (find it with grep — it applies a corner frame and calls `applyFrame`), add after the frame is applied:

```swift
controller?.updateSizeLimits()
```

If `PositionManager` does not have a reference to `PanelController`, add the call in `PanelController.cycleCorner()` instead:

**File:** `Sources/TerminalFly/Window/PanelController.swift`

Update `cycleCorner()` (line 144):

```swift
func cycleCorner() -> PanelCorner {
    let next = positions.cycleCorner()
    updateSizeLimits()
    return next
}
```

**Verification:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
# Expected: ==> built .../build/TerminalFly.app
```

### Step 4: Clamp frame in `windowDidEndLiveResize` as a safety net
**File:** `Sources/TerminalFly/Window/PanelDelegate.swift`

The delegate needs access to the screen's visible frame to clamp. Add a `clampFrame` callback:

Update the `PanelDelegate` init and add a stored property:

```swift
final class PanelDelegate: NSObject, NSWindowDelegate {
    private let onFrameChange: (NSRect) -> Void
    private let onCustomFrame: () -> Void
    private let clampFrame: (NSRect) -> NSRect

    init(onFrameChange: @escaping (NSRect) -> Void,
         onCustomFrame: @escaping () -> Void,
         clampFrame: @escaping (NSRect) -> NSRect = { $0 }) {
        self.onFrameChange = onFrameChange
        self.onCustomFrame = onCustomFrame
        self.clampFrame = clampFrame
    }
```

Update `windowDidEndLiveResize`:

```swift
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let clamped = clampFrame(window.frame)
        if clamped != window.frame {
            window.setFrame(clamped, display: true, animate: false)
        }
        onFrameChange(clamped)
        onCustomFrame()
    }
```

**File:** `Sources/TerminalFly/Window/PanelController.swift`

Update the `PanelDelegate` init (around line 41) to pass a clamp closure:

```swift
windowDelegate = PanelDelegate(
    onFrameChange: { [weak panel] frame in
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "panelFrame")
    },
    onCustomFrame: { [weak positions] in
        guard let positions, !positions.isProgrammaticMove else { return }
        positions.markCustomFrame()
    },
    clampFrame: { [weak self] frame in
        guard let self else { return frame }
        let visible = (self.panel.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let max = PanelGeometry.maximumSize(in: visible)
        let w = min(max.width, max(PanelGeometry.minimumWidth, frame.width))
        let h = min(max.height, max(PanelGeometry.minimumHeight, frame.height))
        return CGRect(origin: frame.origin, size: CGSize(width: w, height: h))
    }
)
```

**Verification:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
# Expected: ==> built .../build/TerminalFly.app
```

### Step 5: Add width clamp to `PanelGeometry.resized` — make it handle both axes
**File:** `Sources/TerminalFly/Window/PanelGeometry.swift`

Add a new method after `resized(_:byHeightDelta:in:)` (line 73):

```swift
/// Grows or shrinks the width while keeping the right edge fixed (for
/// left-anchored panels) — mirrors the height clamp logic.
static func resizedWidth(_ frame: CGRect, byWidthDelta delta: CGFloat,
                         in visibleFrame: CGRect) -> CGRect {
    let maximum = visibleFrame.width - margin * 2
    let clamped = max(minimumWidth, min(frame.width + delta, maximum))
    var result = frame
    result.size.width = clamped
    return result
}
```

**Verification:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
# Expected: ==> built .../build/TerminalFly.app
```

### Step 6: Write failing tests for width clamp and exact max-height
**File:** `Sources/TerminalFly/Testing/GeometryTests.swift`

Add inside the `"PanelGeometry — height resize"` group, after the `huge` test (line 72):

```swift
// Exact max-height assertion (current test only checks <= screen.height)
TestHarness.equal(huge.height, screen.height - PanelGeometry.margin * 2,
                  "max height is exactly visibleFrame.height minus two margins")
```

Add a new test group after the height group (after line 73):

```swift
TestHarness.group("PanelGeometry — width resize") {
    let base = PanelGeometry.frame(for: .topRight, size: size, in: screen)

    let grown = PanelGeometry.resizedWidth(base, byWidthDelta: 100, in: screen)
    TestHarness.equal(grown.width, 720, "grows width by the requested delta")

    let shrunk = PanelGeometry.resizedWidth(base, byWidthDelta: -100, in: screen)
    TestHarness.equal(shrunk.width, 520, "shrinks width by the requested delta")

    let tiny = PanelGeometry.resizedWidth(base, byWidthDelta: -10_000, in: screen)
    TestHarness.equal(tiny.width, PanelGeometry.minimumWidth,
                      "will not shrink below minimumWidth")

    let huge = PanelGeometry.resizedWidth(base, byWidthDelta: 10_000, in: screen)
    TestHarness.equal(huge.width, screen.width - PanelGeometry.margin * 2,
                      "max width is exactly visibleFrame.width minus two margins")
    TestHarness.expect(PanelGeometry.isFullyVisible(huge, in: screen),
                       "a max-width panel is still fully on screen")
}

TestHarness.group("PanelGeometry — maximumSize helper") {
    let max = PanelGeometry.maximumSize(in: screen)
    TestHarness.equal(max.width, screen.width - 48, "max width = visible - 2*margin")
    TestHarness.equal(max.height, screen.height - 48, "max height = visible - 2*margin")
}
```

**Verify tests fail:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
build/release/TerminalFly --test 2>&1 | grep -E "FAIL|max width|max height|maximumSize"
# Expected: FAIL on new tests (resizedWidth doesn't exist yet for the width group,
#           but the exact max-height assertion should pass since the clamp is correct)
```

Wait — `resizedWidth` was added in Step 5, so the width tests should pass. The exact max-height test might fail if the current `<=` assertion was hiding an off-by-one. Run and check:

```bash
build/release/TerminalFly --test 2>&1 | tail -5
# Expected: PASS: N checks, 0 failures (where N = 157 + new tests)
```

If the exact max-height assertion fails, the clamp in `resized()` has a bug — investigate and fix.

### Step 7: Add UI test verifying `maxSize` is set
**File:** `Sources/TerminalFly/Testing/UITests.swift`

Find the existing resize test group (around line 111) and add after it:

```swift
TestHarness.group("Panel — maxSize is bounded by screen") {
    let controller = PanelController()
    let panel = controller.panel
    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let expected = PanelGeometry.maximumSize(in: visible)

    TestHarness.expect(panel.maxSize.width <= expected.width + 1,
                       "panel.maxSize.width is bounded by screen (got \(panel.maxSize.width), expected <= \(expected.width))")
    TestHarness.expect(panel.maxSize.height <= expected.height + 1,
                       "panel.maxSize.height is bounded by screen (got \(panel.maxSize.height), expected <= \(expected.height))")
    TestHarness.expect(panel.minSize.width >= PanelGeometry.minimumWidth,
                       "panel.minSize.width is set (got \(panel.minSize.width))")
    TestHarness.expect(panel.minSize.height >= PanelGeometry.minimumHeight,
                       "panel.minSize.height is set (got \(panel.minSize.height))")
}
```

**Verify:**
```bash
cd ~/Documents/terminal-fly && bash scripts/build.sh release 2>&1 | tail -3
build/release/TerminalFly --uitest 2>&1 | tail -5
# Expected: PASS with new checks included
```

### Step 8: Run full verify suite
```bash
cd ~/Documents/terminal-fly && bash scripts/verify.sh release 2>&1 | tail -5
# Expected: ALL CHECKS PASSED
```

### Step 9: Commit
```bash
cd ~/Documents/terminal-fly && git add -A && git commit -m "Clamp panel resize to screen bounds

Set panel.maxSize/minSize from visibleFrame so mouse drag cannot
exceed monitor edges. Add PanelGeometry.resizedWidth() for width
clamping. Add safety-net clamp in windowDidEndLiveResize. Tighten
the max-height test from <= screen.height to the exact clamp value."
```

## Tests / validation

| Step | Command | Expected output |
|------|---------|-----------------|
| 1-5 | `bash scripts/build.sh release 2>&1 \| tail -3` | `==> built .../TerminalFly.app` |
| 6 | `build/release/TerminalFly --test 2>&1 \| tail -5` | `PASS: N checks, 0 failures` (N > 157) |
| 7 | `build/release/TerminalFly --uitest 2>&1 \| tail -5` | PASS with new maxSize checks |
| 8 | `bash scripts/verify.sh release 2>&1 \| tail -5` | `ALL CHECKS PASSED` |

Manual verification after implementation:
1. Launch Terminal Fly
2. Drag panel edge to grow — should stop at screen edge minus margin
3. Use ⌃⌥↓ hotkey to grow height — should stop at max height
4. Panel should never extend beyond visible screen area

## Risks, tradeoffs, and open questions

1. **`maxSize` and multi-display** — When panel moves to a different screen, `maxSize` must be recalculated. Step 3 handles this for `cycleCorner()`, but if the user drags the panel to another screen manually, `windowDidMove` should also trigger `updateSizeLimits()`. Consider adding this to `PanelDelegate.windowDidMove` or `PositionManager`.

2. **`maxSize` vs drag position** — Setting `maxSize` constrains size but not position. A panel at max size dragged to straddle two screens could still overflow. The `clampFrame` safety net in Step 4 only clamps size, not position. This is acceptable — position overflow is a separate concern from the resize bug.

3. **`minSize` might conflict with terminal rendering** — If `minimumWidth = 300` is too narrow for SwiftTerm to render without errors, increase it. Verify by setting panel to min size and running `htop`.

4. **Screen change during live resize** — If the user drags the panel across displays mid-resize, `maxSize` from the old screen applies until `windowDidEndLiveResize` fires. Edge case, unlikely to cause visible issues.
## Execution log — 2026-09-27

Shipped. `--test` 182 checks / 0 failures (was 157), `--uitest` 47 checks / 0
failures, `scripts/verify.sh release` → `ALL CHECKS PASSED`.

Deviations from the steps above, all deliberate:

1. **Step 2/3 placement.** `updateSizeLimits()` lives on `PositionManager`, not
   `PanelController`: that class already owns the panel reference *and* the
   `NSWindow.didChangeScreenNotification` observer, so no controller↔positions
   callback was needed. Called from `init`, after `move(to:)`, on screen change,
   and after `restore()`. Step 3's `cycleCorner()` edit became unnecessary —
   `cycleCorner → move(to:) → updateSizeLimits()`. This also closes Risk 1 (a
   manual drag to another display), not just the corner-cycle path.
2. **Step 4 fallback was a bug.** The plan's `?? CGRect(0, 0, frame.width, frame.height)`
   makes `maximumSize` = frame − 2×margin, so a screen-less call *shrinks* the
   panel by 48pt. Replaced with `guard let visible … else { return frame }`
   (no clamp when the display is unknown). Same latent phantom-shrink existed in
   `adjustHeight`'s fallback; also now guard-return. `updateSizeLimits()` skips
   AppKit's unconstrained default rather than inventing a display.
3. **Step 5 contradicted Step 6.** `resizedWidth` as written left the origin
   alone, i.e. pinned the *left* edge; for the `.topRight` base the plan asserts
   `isFullyVisible(huge)` on, maxX would land at 3148 in a 1920-wide frame.
   Implemented as the true mirror of `resized()`: the margin-anchored edge is
   pinned (right edge for a right-parked panel, left for a left-parked one), so
   the panel keeps hugging its corner. Both left- and right-anchored cases are
   now covered by tests.
4. **Step 5 would have been dead code.** Nothing called `resizedWidth`. Wired it
   end to end: `PositionManager.adjustWidth(by:)`, `PanelController.growWidth()`
   / `shrinkWidth()`, new hotkeys `⌃⌥→` / `⌃⌥←` (`HotkeyAction.increaseWidth` /
   `decreaseWidth`), menu-bar items, README table. The 24pt step moved to
   `PanelGeometry.resizeStep` (was a literal in four places).
5. **Extra clamp sites.** Corner presets and `restore()` now run the frame
   through `PanelGeometry.clamped(_:in:)` first, so a size saved on a bigger
   display cannot come back overflowing the current one.
6. **UI-test hygiene.** `--uitest` drives the real panel against the user's real
   `UserDefaults`, and a running app instance competes for the same domain — the
   first version of the width tests failed on the *second* run because the first
   left the panel at `minimumWidth`. The suite now snapshots and restores
   `panelFrame` / `panelCorner` / `panelUsesCustomFrame`, and the height and
   width hotkey groups start from an explicit frame. Two consecutive `--uitest`
   runs pass.
7. **Step 6 outcome.** Tightening `huge.height <= screen.height` to the exact
   clamp found no off-by-one — the existing height clamp was already correct, so
   the assertion is now a real regression guard.
8. **New test beyond the plan.** `PanelDelegate — a resize that escapes the
   limits is pulled back` proves `windowDidEndLiveResize` does the clamping: it
   lifts `maxSize` away, applies an oversize frame, asserts the frame really is
   oversize, posts `NSWindow.didEndLiveResizeNotification`, and asserts the
   result is exactly `maximumSize` and on screen.

   Correction to the first draft of this note: `NSWindow.setFrame` **does**
   enforce `maxSize` (measured: a 2372×1455 request came back as 1872×955, and
   `constrainFrameRect` also moved the origin onto the screen). That is why the
   test has to lift the ceiling before it can exercise the delegate at all.
   Posting the notification does reach the delegate — AppKit dispatches window
   notifications through the shared `NotificationCenter`, so the test drives the
   real callback path rather than calling the method by hand.

## Follow-up: size clamp was not enough (same day)

Reported after the commit: growing a *small* panel tall still left the bottom
rows hidden below the screen. Reproduced the shape — a panel whose top edge sits
low on the screen, grown to a height that is perfectly legal.

Cause: two independent bounds, and only one was enforced. `maxSize` caps size;
`PanelGeometry.resized()` pins the **top** edge, so the growth is pushed
downwards. A 955pt panel with its top 127pt below the menu bar ends up entirely
legal in size and ~79pt off the bottom. The user's screenshot measured 1002pt
tall, which is above this display's 955pt ceiling — that part was the pre-fix
binary still running (started 16:44, binary rebuilt 17:22), and `restore()` now
repairs that saved frame on the next launch.

Fix: `PanelGeometry.contained(_:in:)` — pulls a size-clamped frame back inside
`visibleFrame`, moving it as little as possible. Applied in `resized`,
`resizedWidth` and `clamped`, so every path that can produce a frame
(hotkey, corner preset, restore, end-of-live-resize) ends fully on screen.

`+10` logic checks (192), `+6` UI checks (53), including an oversize custom
frame saved off-screen being restored both inside `maximumSize` and fully
visible.

Still unverified (needs the running app, Risk 3): `minimumWidth = 300` with
SwiftTerm. Drag a panel to its narrowest size and run `htop`.
