# Fix: Panel resize has no screen-bounds limit

**Status: shipped, confirmed on real hardware by the user (2026-09-27).** Commits
`99fc890` (size clamp + width control) and `76649c4` (position clamp). Steps 1-9
below are the *original* plan; each blockquote under a step and the
[execution log](#execution-log--2026-09-27) record where the plan was wrong and
what actually shipped. Read those before reusing any snippet — Steps 2, 4 and 5
contain code that is incorrect as written.

## Goal
Clamp panel width and height to the current screen's visible frame so the panel cannot be resized (by hotkey or mouse drag) beyond the monitor edges.

*Amended after shipping:* the goal is not only a size bound but **the panel stays
inside the visible area**. `maxSize` alone was insufficient — a panel whose top
edge sits low on the screen can grow to a perfectly legal height and still hang
off the bottom. See [Follow-up](#follow-up-size-clamp-was-not-enough-same-day).

## Current context / assumptions
- Project: `~/Documents/terminal-fly/` — Swift macOS app, planned at commit `30bd9cd`, shipped at `76649c4`
- Build: `bash scripts/build.sh release` → app bundle at `build/TerminalFly.app`
- Tests: `build/TerminalFly.app/Contents/MacOS/TerminalFly --test` (headless logic), `--uitest` (needs a window server)
- Verify: `bash scripts/verify.sh release` runs all checks
- **No Xcode on this machine** — `swiftc` direct compile via `scripts/build.sh`
- **A running instance shares the `UserDefaults` domain the tests use.** Size limits
  only exist in the binary that is actually running, so relaunch before retesting a
  visual fix — this cost one debugging round.

### Root cause (three separate gaps)

**Gap 1 — Mouse drag resize is completely unbounded.**
`PanelController.swift` line 35 creates the panel with `.resizable` style mask but never sets `panel.maxSize`. AppKit default is "no maximum." The user can drag the panel edge past the screen boundary, and the overflow is cropped/invisible. `PanelDelegate.swift` only saves the frame in `windowDidEndLiveResize` — it never clamps.

**Gap 2 — Hotkey height grow is clamped but width is not handled.**
`PanelGeometry.resized()` (line 66) clamps height to `visibleFrame.height - margin * 2`. This works for height. But there is no width resize hotkey and no width clamp function. The user asked for "max width based on monitor resolution" — currently width can only change via mouse drag, which has no limit (Gap 1).

**Gap 3 — A size bound is not a position bound. Found after shipping, not in the
original analysis.**
`resized()` pins the **top** edge, so growth is pushed downwards. A panel with its
top edge below the menu bar can reach the maximum legal height and still hang off
the bottom — `maxSize` satisfied, `visibleFrame` not. Nothing in the geometry
guaranteed the position, and the fix does not rely on AppKit to: `contained(_:in:)`
does it explicitly. (The user's screenshot measured 1002pt on a 955pt ceiling, so
that capture was the pre-fix binary; the shape behind it is nevertheless real —
`resized()` on a panel at `y = 200` grown to the 937pt maximum lands `minY` at
-577, which is what the containment tests now pin down.)

### Key files
- `Sources/TerminalFly/Window/PanelGeometry.swift` — pure geometry, clamping logic
- `Sources/TerminalFly/Window/PanelController.swift` — panel creation, `grow()`/`shrink()`, `growWidth()`/`shrinkWidth()`
- `Sources/TerminalFly/Window/PositionManager.swift` — `updateSizeLimits()`, `adjustHeight(by:)`, `adjustWidth(by:)`, applies frames
- `Sources/TerminalFly/Window/PanelDelegate.swift` — `NSWindowDelegate`, frame persistence, `clampFrame` safety net
- `Sources/TerminalFly/Hotkeys/Hotkey+Extensions.swift`, `HotkeyManager.swift` — width actions `⌃⌥→` / `⌃⌥←`
- `Sources/TerminalFly/MenuBar/MenuBarController.swift` — Grow / Shrink, height and width
- `Sources/TerminalFly/Testing/GeometryTests.swift` — headless geometry tests
- `Sources/TerminalFly/Testing/UITests.swift` — window-server UI tests
- `README.md` — shortcut table + the resize-bounds paragraph

## Architecture / proposed approach
Set `panel.maxSize` and `panel.minSize` at creation and on screen change so AppKit itself enforces bounds during mouse drag. Add a `PanelGeometry.resizedWidth()` function mirroring the existing height clamp. Update `windowDidEndLiveResize` to clamp-and-correct if a drag somehow exceeded bounds (belt + suspenders). Add unit tests for width clamping and for the exact max-height value (current test only asserts `<= screen.height`, not the precise clamp).

**As shipped, one layer more:** every frame-producing path (both hotkey axes, corner
presets, `restore()`, end-of-live-resize) finishes with
`PanelGeometry.contained(_:in:)`, which pulls a size-clamped frame back inside
`visibleFrame` by the smallest possible movement. `maxSize` handles the drag;
`contained` handles the position. Architecture otherwise unchanged, except
`updateSizeLimits()` lives on `PositionManager` (which already owns the panel and
the `didChangeScreenNotification` observer) rather than `PanelController`.

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
> **Wrong as written.** The `?? CGRect(x: 0, y: 0, width: 1920, height: 1080)`
> fallback invents a display; the shipped version returns early when no screen is
> known, leaving AppKit's unconstrained default. The method also lives on
> `PositionManager`. See [deviation 1 and 2](#execution-log--2026-09-27).

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
> **Superseded.** Neither variant shipped. `PositionManager` owns the limits *and*
> the existing `NSWindow.didChangeScreenNotification` observer, so the update is
> wired there: `init`, the screen-change observer, `move(to:)` (hence `cycleCorner`)
> and `restore()`. That covers every path, not just the corner cycle.
> See [deviation 1](#execution-log--2026-09-27).

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
> **Partly wrong as written.** The closure's `?? CGRect(0, 0, frame.width,
> frame.height)` fallback makes `maximumSize` = frame − 2×margin, so it *shrinks*
> a panel by 48pt whenever no screen is known; shipped as an early return. The
> arithmetic moved into `PanelGeometry.clamped(_:in:)`, and — added after the
> first ship — that helper now corrects **position** as well as size.

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
> **Wrong as written, and it had no caller.** Leaving `result.origin.x` alone pins
> the *left* edge, which fails this plan's own Step 6 `isFullyVisible(huge)`
> assertion for a `.topRight` base (maxX lands at 3148 in a 1920-wide frame). The
> shipped version pins the margin-anchored edge, and `resizedWidth` is reachable
> through `adjustWidth(by:)` → `growWidth()` / `shrinkWidth()` → `⌃⌥→` / `⌃⌥←` +
> menu items.

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
> Resolved as written-and-then-doubted: the exact max-height assertion **passed**
> immediately (the existing height clamp was already correct — the loose `<=` was
> hiding nothing), and the width group could **not** pass until the Step 5 anchor
> bug was fixed. So the failing test pointed at Step 5, not at `resized()`.

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
> **Looser than it needed to be.** The planned checks do catch the broken build —
> measured AppKit defaults are `maxSize = 3.4e38` (FLT_MAX) and `minSize = (0, 0)`,
> so `<= expected + 1` and `>= minimumWidth` both fail pre-fix. But `<=` would also
> pass a ceiling that is far too small (limits computed from the wrong display), and
> `>=` passes anything oversized. The shipped group asserts exact equality against
> `maximumSize` and both minima, and is joined by four more: real width/height
> hotkey behaviour, an oversize custom frame restored on screen, growth from a
> mid-screen start, and the end-of-live-resize clamp.

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
> **Narrowed.** `git add -A` would have swept in `.hermes/plans/2026-09-27_1200-…`,
> an unrelated prior-session edit, so only the resize files, README and this plan
> were staged. The work also landed as two commits — the position clamp is a
> distinct fix with its own repro: `99fc890`, then `76649c4`.

```bash
cd ~/Documents/terminal-fly && git add -A && git commit -m "Clamp panel resize to screen bounds

Set panel.maxSize/minSize from visibleFrame so mouse drag cannot
exceed monitor edges. Add PanelGeometry.resizedWidth() for width
clamping. Add safety-net clamp in windowDidEndLiveResize. Tighten
the max-height test from <= screen.height to the exact clamp value."
```

## Tests / validation

Planned vs. actual:

| Step | Command | Planned | Actual |
|------|---------|---------|--------|
| 1-5 | `bash scripts/build.sh release` | `==> built .../TerminalFly.app` | same |
| 6 | `... --test` | `PASS: N checks` (N > 157) | `PASS: 192 checks, 0 failures` |
| 7 | `... --uitest` | PASS with new maxSize checks | `PASS: 53 checks, 0 failures`, twice in a row |
| 8 | `bash scripts/verify.sh release` | `ALL CHECKS PASSED` | `ALL CHECKS PASSED` |

Manual verification after implementation — **all confirmed by the user on the
shipped build**:
1. Launch Terminal Fly ✅
2. Drag panel edge to grow — should stop at screen edge minus margin ✅
3. Use ⌃⌥↓ hotkey to grow height — should stop at max height ✅ (also ⌃⌥→ for width)
4. Panel should never extend beyond visible screen area ✅ — **this is the one
   `maxSize` alone did not deliver**; it needed `contained(_:in:)`. See
   [Gap 3](#root-cause-three-separate-gaps).

## Risks, tradeoffs, and open questions

1. **`maxSize` and multi-display** — RESOLVED, differently than planned. Limits are
   recomputed in `PositionManager.updateSizeLimits()`, called from `init`, the
   existing `NSWindow.didChangeScreenNotification` observer, `move(to:)`, and
   `restore()` — so a manual drag to another display is covered without touching
   `windowDidMove` (which fires continuously and would thrash the limits mid-drag).

2. **`maxSize` vs drag position** — Was written off as "a separate concern". **It
   turned out to be the bug that was actually reported.** A size-only clamp let a
   low-positioned panel grow legal and still hang off the bottom. Resolved by
   `PanelGeometry.contained(_:in:)`, applied after every size clamp. What is still
   open is *pure repositioning*: dragging an unchanged-size panel partly off screen
   is not corrected until the next resize, deliberately — `windowDidMove` fires
   throughout the drag and snapping there would fight the user.

3. **`minSize` might conflict with terminal rendering** — OPEN. `minimumWidth = 300`
   (~45 columns at the default size) is unverified against SwiftTerm. Shrink the
   panel to its narrowest and run `htop`; raise the constant if it garbles.

4. **Screen change during live resize** — MITIGATED. The old screen's `maxSize`
   applies during the gesture, but `windowDidEndLiveResize`'s clamp runs against
   the *current* `visibleFrame` and `contained` fixes both axes, so the escape is
   corrected on mouse-up. Not verified on real hardware: single-display machine.

5. **Scope added beyond the plan** — width control did not exist at all, and a
   `resizedWidth()` helper nobody calls is dead weight, so Step 5 was wired through
   `adjustWidth(by:)` to `⌃⌥→` / `⌃⌥←` and the menu. Flagged during review as
   feature drift against a clamping-only mandate; kept because it is the only
   keyboard path to the width bound, is covered by tests, and the original ask was
   "max width based on monitor resolution".

## Execution log — 2026-09-27

Shipped, then amended: `--test` **192** checks / 0 failures, `--uitest` **53**
checks / 0 failures (from 157 and 35), `scripts/verify.sh release` →
`ALL CHECKS PASSED`. Commits `99fc890` (size clamp) + `76649c4` (position clamp).

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
   limits is pulled back`. The delegate net's job is not to catch `setFrame`
   escaping — it does not — but to correct a frame that is already out of bounds
   when the limits change under it: a frame saved before the limits existed, a
   frame resized while the ceiling belonged to another display. To exercise that
   path the test lifts `maxSize` away, applies an oversize frame, asserts the
   frame really is oversize, posts `NSWindow.didEndLiveResizeNotification`, and
   asserts the result is exactly `maximumSize` and on screen.

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
SwiftTerm. Drag a panel to its narrowest size and run `htop`. The user confirmed
the growth clamping works on real hardware; the narrow-render case was not part
of that check.

## Shipped surface

`PanelGeometry` (pure, headless-tested):

| Member | Guarantees |
|--------|-----------|
| `margin = 24`, `minimumHeight = 120`, `minimumWidth = 300`, `resizeStep = 24` | the four numbers every clamp reads |
| `maximumSize(in:)` | `visibleFrame` minus 2×margin on both axes |
| `resized(_:byHeightDelta:in:)` | height capped, top edge pinned, then contained |
| `resizedWidth(_:byWidthDelta:in:)` | width capped, margin-anchored edge pinned, then contained |
| `clamped(_:in:)` | size into `[minimum, maximumSize]`, then contained |
| `contained(_:in:)` *(private)* | smallest origin move that puts the frame fully inside `visibleFrame` |

`PositionManager`: `updateSizeLimits()` (AppKit's `maxSize` / `minSize`),
`adjustHeight(by:)`, `adjustWidth(by:)`. `PanelDelegate`: `clampFrame` closure,
applied in `windowDidEndLiveResize`. `PanelController`: `grow` / `shrink` /
`growWidth` / `shrinkWidth`. `HotkeyAction`: `increaseWidth` (`⌃⌥→`),
`decreaseWidth` (`⌃⌥←`).

Three layers, each with a distinct job — keep all three:
1. `maxSize` / `minSize` → bounds a **mouse drag** while it happens (AppKit).
2. `resized` / `resizedWidth` → bounds a **hotkey** before the frame is applied.
3. `contained` → bounds **position**, which neither of the above can do.

AppKit behaviour measured on this machine (1920×1080, menu bar + Dock →
`visibleFrame = (0, 47, 1920, 1003)`, so `maximumSize = (1872, 955)`):

| Fact | Consequence |
|------|-------------|
| Default `maxSize` is FLT_MAX, default `minSize` is `(0, 0)` | unset limits mean *no* drag bound — the original Gap 1 |
| `setFrame` clamps an oversize request to `maxSize` (measured: 2372×1455 → 1872×955) | the size ceiling holds for programmatic frames too, not just live drags |
| AppKit's own frame placement does not bound position to `visibleFrame` | observed directly: the reported panel sat with rows under the Dock at a size that was legal — `contained` is what closes that |
| Posting `NSWindow.didEndLiveResizeNotification` reaches `windowDidEndLiveResize` | tests can drive the real mouse-up callback without a human |

## Changelog

- 2026-09-27: **Plan executed + amended, confirmed on hardware.** `99fc890` set
  `maxSize`/`minSize` from `visibleFrame`, added `maximumSize`, `clamped`,
  `resizedWidth` and an end-of-`live-resize` clamp, and wired width control
  (`⌃⌥→`/`⌃⌥←`, menu) so `resizedWidth` was not dead code. `76649c4` added
  `contained(_:in:)` after the reported case showed a size bound is not a position
  bound. Steps 2/4/5 of this plan contained bugs as written — each is annotated in
  place and reconciled in the [execution log](#execution-log--2026-09-27).
  Logic checks 157 → 192, UI checks 35 → 53.
