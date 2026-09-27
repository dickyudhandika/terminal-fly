# Terminal Fly — Always-On-Top Terminal for macOS

## Status
IMPLEMENTED (Steps 1–8 complete)

## Goal
A lightweight macOS terminal app that stays visible above other apps while you work. Like the kitty + Hammerspoon overlay setup, but as a standalone product — no Hammerspoon, no kitty dependency, works for anyone.

**Product decisions (locked 2026-09-27):**
- **Name**: Terminal Fly (keeping it)
- **License**: MIT, open source
- **Distribution**: Direct (DMG + notarization). No App Store — sandbox kills PTY fork.
- **Focus model**: Option A — click panel to type, click away to give focus back to underlying app. Simple, predictable, no mode switching.
- **herdr pairing**: Terminal Fly renders, herdr owns the session (Step 8, after standalone works). Clean separation like iTerm2 + tmux. Users without herdr get full standalone product.
- **Platform**: macOS only (14.0+). herdr is macOS-only. Cross-platform = wasted effort.

## Target users
1. **Designers who work in Figma/Sketch + need terminal visible** — primary user. Terminal floats over design tool, no alt-tab.
2. **Developers running long tasks** (dev server, tests, builds) who want terminal visible while coding in another window.
3. **herdr users** — people using herdr for terminal orchestration who want a floating display for their panes. Differentiator vs oTerm/Opus/Backgrind — none pair with a terminal multiplexer.

## Context
- Working prototype exists as Hammerspoon + kitty combo (see wiki: `[[kitty-sticky-panel-macos]]`)
- **Core constraint discovered**: macOS has NO API to set another app's window level. Deliberate sandbox boundary. The floating window must be one the app itself owns.
- Current setup exploits this: `kitten quick-access-terminal` at `layer overlay` = kitty owns the window, so it can float. Hammerspoon just launches + parks it.
- **Product insight**: if we build our OWN terminal app, `NSWindow.level = .floating` works natively. No hack needed. The whole Hammerspoon complexity exists only because we were controlling kitty from outside.
- Project dir: `~/Documents/terminal-fly/` (empty, clean slate)
- Platform: macOS 26.x (current user machine), Swift/SwiftUI/AppKit

## Requirements

### Must have (P0)
- Terminal window that floats above other apps (NSWindow.level = .floating)
- Toggle show/hide via global hotkey
- Click-through to underlying app optional (focus stays in design tool when reading terminal)
- Transparency / background opacity control
- Position presets: 4 corners + custom drag
- Remembers last position + size across launches
- Basic terminal functionality: shell (bash/zsh), text output, command input
- Resize by drag (not locked like kitty overlay)

### Should have (P1)
- Multiple panels / tabs
- Font + size configuration
- Color themes (dark/light + custom)
- Launch at login
- Menu bar icon for quick access
- Keyboard shortcuts: toggle, resize, cycle corner
- Paste support (Cmd+V)
- Split pane (vertical/horizontal)

### Nice to have (P2)
- Profiles (different shells, different positions, different opacity per use case)
- SSH integration
- Global hotkey customization UI
- Clipboard history strip
- Auto-hide on app switch (smart focus detection)
- Sparkle auto-update
- App Store distribution

## Architecture / Design

### Why this works when Hammerspoon struggled

```
Hammerspoon approach (current):
  Hammerspoon → launches kitty panel → kitty owns window → kitty sets layer overlay
  Problem: controlling foreign app, complex launch/detect/resize logic, socket hacking

Terminal Fly approach (product):
  Terminal Fly IS the app → owns the window → NSWindow.level = .floating
  Done. No external controller, no socket, no IPC, no Hammerspoon.
```

The entire wiki page of dead ends (`hs.window:setLevel` doesn't exist, `raise()` steals focus, AX API has no level setter) vanishes when you own the window. `NSWindow.level = .floating` is a one-liner.

### Tech stack

- **Language**: Swift 6
- **UI**: SwiftUI + AppKit interop (NSWindow needed for level control; SwiftUI alone can't set window level directly)
- **Terminal emulator**: SwiftTerm (https://github.com/migueldeicaza/SwiftTerm) — mature Swift terminal emulator, used in many macOS apps, supports VT100/xterm, true color, mouse, etc.
- **Hotkeys**: Carbon API (`RegisterEventHotKey`) via a Swift wrapper — global hotkeys need Carbon, not SwiftUI `.keyboardShortcut`
- **Window management**: AppKit `NSPanel` or `NSWindow` with `.floating` level
- **Persistence**: UserDefaults / SwiftData for position, size, opacity, font prefs
- **Min macOS**: 14.0 (Sonoma) — SwiftUI maturity + broad install base

### Window type decision

Two options:

| Option | Pros | Cons |
|--------|------|------|
| `NSWindow` + `.floating` level | Full window behavior, resize, standard chrome | Steals focus on click (unless we override) |
| `NSPanel` with `styleMask = .nonactivatingPanel` | Doesn't steal focus by default, designed for floating panels | Some standard window behaviors need manual wiring |

**My take**: Use `NSPanel` with `.nonactivatingPanel` + `.titled` + `.resizable` + `.closable` + `.miniaturizable`. This gives us:
- Floating level by default (NSPanel is designed for this)
- Non-activating = clicking the panel doesn't bring Terminal Fly to front, underlying app keeps focus
- Still resizable + movable
- Can override `canBecomeKey` to accept keyboard input when explicitly clicked

This matches the kitty `hide_on_focus_loss no` + `layer overlay` behavior natively.

### App structure

```
TerminalFly/
├── TerminalFlyApp.swift          // @main, App protocol, menu bar setup
├── Window/
│   ├── PanelController.swift     // NSPanel lifecycle, level, position, show/hide
│   ├── PanelDelegate.swift       // Window delegate: focus, close, resize events
│   └── PositionManager.swift     // Corner presets, save/restore position
├── Terminal/
│   ├── TerminalView.swift        // SwiftTerm wrapper (SwiftUI representable)
│   ├── TerminalDelegate.swift    // SwiftTerm delegate: shell I/O, size changes
│   └── ShellProcess.swift        // PTY spawn (forkpty + execvp /bin/zsh)
├── Hotkeys/
│   ├── HotkeyManager.swift       // Carbon RegisterEventHotKey wrapper
│   └── Hotkey+Extensions.swift   // Key code mappings
├── Settings/
│   ├── SettingsView.swift        // SwiftUI settings window
│   ├── AppearanceSettings.swift  // Font, opacity, theme
│   ├── HotkeySettings.swift      // Hotkey customization
│   └── PreferencesStore.swift    // UserDefaults / SwiftData models
├── MenuBar/
│   └── MenuBarController.swift    // NSStatusItem, menu bar icon + menu
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

### Data flow

```
User presses global hotkey (⌃⌥P)
  → HotkeyManager fires callback
  → PanelController.togglePanel()
  → If panel hidden: show NSPanel, restore saved position, activate shell
  → If panel visible: hide NSPanel (don't kill shell — keep session alive)

User types in panel:
  → SwiftTerm TerminalView captures keystrokes
  → TerminalDelegate sends bytes to ShellProcess (PTY stdin)
  → ShellProcess reads PTY stdout → forwards to TerminalView
  → SwiftTerm renders output

User drags panel:
  → PanelDelegate.windowDidChangeFrame notification
  → PositionManager saves new frame to UserDefaults
```

### UI wireframes

```
┌─ Terminal Fly ──────────────────────── ♂ ─┐
│                                          │
│  $ npm run dev                            │
│  Server running on localhost:3000        │
│  ^C                                       │
│  $ _                                      │
│                                          │
└──────────────────────────────────────────┘
  ↑ floating above Figma/editor/whatever
  ↑ semi-transparent (opacity configurable)
  ↑ click underlying app → panel stays visible, focus moves to app
```

Menu bar dropdown:
```
 Terminal Fly
 ─────────────
 [✓] Show Panel        ⌃⌥P
 ─────────────
 Position
   [✓] Bottom-Right
   ○ Bottom-Left
   ○ Top-Right
   ○ Top-Left
   ○ Last Used
 ─────────────
 Opacity: ████████░░ 80%
 ─────────────
 Settings…
 Quit Terminal Fly
```

Settings window:
```
┌─ Settings ──────────────────────────────┐
│  [General] [Appearance] [Hotkeys] [Shell]│
│                                          │
│  Appearance tab:                         │
│    Font:      [SF Mono          ▾]       │
│    Size:      [12.5            ]          │
│    Theme:     [Dark            ▾]        │
│    Opacity:   [━━━━━━━━━━░░] 80%        │
│    □ Transparent when unfocused          │
│                                          │
│  Hotkeys tab:                            │
│    Toggle panel:    [⌃ ⌥ P    ] [Record] │
│    Cycle corner:    [⌃ ⌥ C    ] [Record] │
│    Height +:        [⌃ ⌥ ↓    ] [Record] │
│    Height -:        [⌃ ⌥ ↑    ] [Record] │
│                                          │
│  Shell tab:                             │
│    Shell:      [/bin/zsh        ]        │
│    Args:       [-l              ]        │
│    Working dir:[$HOME           ]        │
└──────────────────────────────────────────┘
```

## Implementation Steps

### Step 1: Project scaffold + NSPanel floating proof
- What: Create Xcode project (SwiftUI app), wire up NSPanel with `.floating` level + `.nonactivatingPanel`, prove it floats above other apps
- Files: `TerminalFlyApp.swift`, `Window/PanelController.swift`, `Window/PanelDelegate.swift`
- Validation: Launch app, open Figma/browser, panel stays on top, underlying app keeps menu bar

### Step 2: SwiftTerm integration — basic terminal
- What: Add SwiftTerm SPM dependency, wrap in SwiftUI `NSViewRepresentable`, spawn shell via PTY, render output
- Files: `Terminal/TerminalView.swift`, `Terminal/TerminalDelegate.swift`, `Terminal/ShellProcess.swift`
- Validation: Type `echo hello` in panel, see output. Run `htop`, see it render.

### Step 3: Global hotkey toggle
- What: Carbon `RegisterEventHotKey` wrapper, ⌃⌥P toggles panel visibility, launch at login
- Files: `Hotkeys/HotkeyManager.swift`, `Hotkeys/Hotkey+Extensions.swift`
- Validation: Press ⌃⌥P while Figma is focused → panel appears/disappears, Figma keeps focus

### Step 4: Position management
- What: 4 corner presets + custom, save/restore to UserDefaults, `windowsChanged`-like re-parking after screen change
- Files: `Window/PositionManager.swift`
- Validation: Move panel, restart app → returns to last position. Cycle corners via hotkey. External display → panel re-parks.

### Step 5: Settings UI
- What: SwiftUI Settings scene with tabs for appearance (font, opacity, theme), hotkeys (record new combos), shell config
- Files: `Settings/SettingsView.swift`, `Settings/AppearanceSettings.swift`, `Settings/HotkeySettings.swift`, `Settings/PreferencesStore.swift`
- Validation: Change opacity slider → panel updates live. Change font → terminal re-renders. Record new hotkey → old one stops, new one works.

### Step 6: Menu bar icon + quick actions
- What: `NSStatusItem` with dropdown menu (toggle, position, opacity slider, settings, quit)
- Files: `MenuBar/MenuBarController.swift`
- Validation: Click menu bar icon → dropdown shows. Toggle from menu works. Opacity slider in menu works.

### Step 7: Polish + distribution prep
- What: App icon, launch at login (SMAppService), notarization, DMG build, GitHub repo setup (MIT)
- Files: `Resources/Assets.xcassets`, build scripts, `LICENSE`
- Validation: `codesign --verify` passes. `xcrun notarytool submit` accepted. DMG opens on clean machine. GitHub repo public with MIT license.
- Result: icon + DMG + repo done. **Launch at login is implemented AND verified** via `--logintest` (registers, checks `.enabled`, unregisters; self-reversing) — run from `/Applications` to exercise it, since `SMAppService` requires a stable location. Notarization remains blocked on an Apple Developer ID cert.
- **Sparkle auto-update is deferred, not done.** It is P2 ("nice to have") and it cannot be wired up honestly before notarization: Sparkle verifies the signature of the downloaded update and needs an EdDSA-signed appcast with a hosted feed, which is meaningless against an ad-hoc-signed DMG. Implement it once a Developer ID and a release pipeline exist. Tracked in README → Known gaps.

### Step 8: herdr integration
- What: Terminal Fly can connect to herdr instead of spawning own PTY. herdr owns session management (multiplexing, splits, persistence). Terminal Fly becomes floating display + keyboard input for herdr sessions.
- Architecture: herdr spawns PTY → pipes output to Terminal Fly via Unix socket (or similar IPC). Terminal Fly sends keystrokes back to herdr. Standalone mode (own PTY) remains default — herdr mode is opt-in.
- Files: `Herdr/HerdrProtocol.swift`, `Herdr/HerdrClient.swift`, `Herdr/HerdrSession.swift`, `Herdr/HerdrDisplaySurface.swift`, `Herdr/HerdrSelfTest.swift`, `Herdr/HerdrUITests.swift`
- **IPC contract, measured against herdr 0.8.2** (`herdr api schema --json`, protocol 20, 91 methods):
  - Socket: `~/.config/herdr/herdr.sock`, newline-delimited JSON. `id` and the trailing newline are both mandatory.
  - **One request per connection.** The server replies once and closes; a second request on the same socket gets a broken pipe. `events.subscribe` is the exception — it holds the connection open for events but serves no requests.
  - **No output-streaming API.** The 27 subscribable events are metadata only; `pane.updated` fires for title/cwd/focus/status changes, *not* for plain output (verified: zero events after writing to an idle focused pane). So the bridge **polls** `pane.read(source:"visible", format:"ansi")` and repaints only when the text changes.
  - Input: `pane.send_input` (raw bytes; what typing uses) and `pane.send_keys` (named keys like `Enter`, `C-c`).
  - `source:"recent"` returns empty on a pane that has not scrolled — use `source:"visible"`.
- Validation: all three criteria verified end to end by `--herdr-uitest` in a real window against live herdr, using an isolated scratch workspace (never the user's panes): pane output renders in the floating panel; typing in the panel reaches the pane; disconnect falls back to the standalone shell.
- Result: `--herdr-test` (socket layer, 3 sequential requests), `--herdr-uitest` (render + input + fallback, 8 checks), 31 unit checks over the session logic via a fake transport. Both wired into `scripts/verify.sh`.

## Tests / Validation

| Step | How to verify |
|------|---------------|
| 1. Floating | Screenshot: panel overlaps Figma, Figma owns menu bar |
| 2. Terminal | `echo test` → output visible. `vim` → renders correctly. Resize panel → terminal reflows. |
| 3. Hotkey | ⌃⌥P while Figma focused → panel toggles, Figma still frontmost (`hs.application.frontmostApplication()` or check menu bar) |
| 4. Position | Restart app → panel returns to last corner. Hotkey cycle → 4 corners. Unplug external display → panel re-parks on primary. |
| 5. Settings | Opacity slider live-updates. Font change live-updates. Hotkey record replaces binding. |
| 6. Menu bar | Icon visible. Menu actions work. Opacity slider in menu syncs with settings. |
| 7. Distribution | `spctl --assess --verbose=4 TerminalFly.app` passes. DMG installs on clean macOS. GitHub repo live with MIT license. |
| 8. herdr | herdr session detected → output in floating panel. Input reaches herdr. Kill herdr → graceful fallback. |

## Risks & Open Questions

1. **SwiftTerm maturity for our use case** — need to verify: true color support, mouse reporting, resize handling. Mitigation: Step 2 validates this early. If SwiftTerm fails, fallback to xterm.js in WKWebView.

2. **NSPanel + keyboard input tension** — RESOLVED. Decision: Option A (click-to-type). `canBecomeKey = true` on NSPanel allows keyboard input when clicked. Clicking another app gives focus back. No mode switching needed. Verify in Step 1.

3. ~~App Store vs direct distribution~~ — RESOLVED. Direct distribution only. Open source MIT. No App Store — sandbox kills PTY fork.

4. **Global hotkey conflicts** — ⌃⌥ combos are relatively safe but user-customizable hotkeys may conflict with system or other apps. Need conflict detection in hotkey settings.

5. **Multiple displays** — Position save/restore needs to handle display arrangement changes. kitty panel had this issue (re-park on `windowsChanged`). NSWindow has `NSWindow.didChangeScreenNotification` — simpler.

6. **Shell environment** — When launched from Finder (not terminal), the shell won't inherit PATH from `.zshrc` / `.bash_profile` unless we spawn a login shell (`-l` flag). This is a common terminal app gotcha.

7. ~~Name: "Terminal Fly"~~ — RESOLVED. Keeping "Terminal Fly". Trademark search pending but not blocking development.

8. ~~**herdr IPC protocol**~~ — **RESOLVED 2026-09-27.** Contract inspected directly against the
   running herdr 0.8.2 (`herdr api schema --json`, protocol 20, 91 methods) and verified over the
   socket. Details:
   - **Transport**: Unix stream socket at `~/.config/herdr/herdr.sock` (server) and
     `herdr-client.sock` (client). Not HTTP.
   - **Framing**: newline-delimited JSON, one request per line. `id` is REQUIRED — omitting it
     returns `invalid_request: missing field 'id'`. A request without a trailing newline hangs
     (the server waits for the line terminator).
   - **Request**: `{"id": "<correlation>", "method": "<name>", "params": {...}}\n`
   - **Response**: `{"id": "...", "result": {...}}\n` or `{"id": "...", "error": {"code": "...",
     "message": "..."}}\n`
   - **Methods needed**:
     | Need | Method | Params |
     |------|--------|--------|
     | discover panes | `pane.list` | `{workspace_id?: string\|null}` |
     | render output | `pane.read` | `{pane_id, source: visible\|recent\|recent_unwrapped\|detection, lines?, strip_ansi?, format?}` |
     | send keystrokes | `pane.send_text` | `{pane_id, text}` (literal) |
     | send special keys | `pane.send_keys` | `{pane_id, keys: [...]}` — `esc`/`escape` for Escape |
     | run a command | `pane.run` | text + Enter in one call |
     | wait for output | `pane.wait_for_output` | `{pane_id, match: {type: substring\|regex, value}, timeout_ms?}` |
     | live streaming | `events.subscribe` | `{subscriptions: [{type: "pane.updated"}, ...]}` → replies `{"result":{"type":"subscription_started"}}`, then events stream on the same connection |
   - **Live evidence**: `pane.list` returned 3 panes with `pane_id`, `agent`, `agent_status`,
     `cwd`, `focused`, `terminal_title`; `pane.read` returned pane text; unknown methods return a
     JSON error listing valid variants.
   - **Design consequence**: standalone mode stays the default. herdr mode is opt-in and must
     degrade gracefully — if the socket is absent, refuse the connection, or the server exits,
     fall back to the standalone PTY rather than showing a dead panel.

## Competitive landscape

| App | Always-on-top? | Stack | Notes |
|-----|----------------|-------|-------|
| kitty `quick-access-terminal` | Yes (overlay layer) | kitty built-in | Not a standalone product, kitty feature |
| iTerm2 | No always-on-top | Obj-C | Has hotkey window but not floating |
| Terminal.app | No | Obj-C | |
| Warp | No | Rust | AI-focused, not floating |
| TotalTerminal | Yes (legacy) | SIMBL plugin | Discontinued, killed by SIP |
| oTerm (egeyesss/overterm) | Yes | Tauri + Rust + xterm.js | Agent-aware (Claude Code). 2 stars. Cross-platform. |
| Opus (Stark-52/opus) | Yes | Swift + SwiftTerm + NSPanel | Closest to our approach. Claude Code-specific. 1 star. 236 commits. |
| Backgrind | Yes | Commercial, closed source | Agent-aware overlay. macOS + Windows. Click-through, notifications. |
| pi-sticky-prompt | Yes | Swift + NSPanel | Not full terminal — just floating prompt bar for pi CLI. |

**Gap**: No modern, maintained, standalone always-on-top terminal for macOS. TotalTerminal is dead. kitty's overlay is kitty-only. oTerm and Opus are Claude Code-specific. Backgrind is commercial + closed. Terminal Fly = generic, open source, herdr-pairable.

## Changelog
- 2026-09-27: Initial draft. Based on wiki research `[[kitty-sticky-panel-macos]]` + skill `macos-window-automation`. Core insight: owning the window eliminates all Hammerspoon dead ends.
- 2026-09-27: Updated — locked product decisions (name, MIT, direct distribution, click-to-type focus model, herdr pairing as Step 8). Added competitive landscape with oTerm/Opus/Backgrind. Added target users. Resolved open questions 2, 3, 7. Added risk 8 (herdr IPC protocol). Status → REVIEW.
- 2026-09-27: **Steps 1–7 implemented and verified.** Status → IMPLEMENTED.
  - Repo live: https://github.com/dickyudhandika/terminal-fly (public, MIT). 48 files, commit `bcbc317`.
  - Tests: 80 logic checks (`--test`, headless) + 35 window-server checks (`--uitest`). No XCTest — no Xcode.app on this machine.
  - Verified fresh clone builds: submodule pin `fe4fb45` → `./scripts/build.sh release` → `--test` 80/80.
  - DMG mounts, app inside is valid-on-disk + satisfies its Designated Requirement, and its embedded `--test` passes.
  - **Build deviation from plan:** plan assumed XcodeGen + `xcodebuild`, but this machine has Command Line Tools only — `xcodebuild` is unavailable and SwiftPM is broken (its bundled `libPackageDescription.dylib` is missing symbols, so every `Package.swift` fails to link). `scripts/build.sh` compiles with `swiftc` directly, runs SwiftTerm's SPM plugin binary by hand, and assembles the bundle. Same sources.
  - **Blocker found during Step 3:** the old `~/.hammerspoon/figma_pin.lua` prototype (from the kitty setup) binds the same four hotkeys and silently wins, because Hammerspoon starts first at login. Carbon reports success regardless. **`figma_pin.lua` must be disabled** or Terminal Fly's hotkeys will never fire on this machine.
  - **Still open:** notarization needs an Apple Developer ID cert (tooling ready: `scripts/make-dmg.sh --notarize`); launch-at-login (`SMAppService`) untested, needs the app in `/Applications`; multi-display re-parking verified by unit test only (single-display machine). Step 8 (herdr) COMPLETE — IPC contract measured against herdr 0.8.2 and verified end to end.