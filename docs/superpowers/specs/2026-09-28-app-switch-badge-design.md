# Show the layout badge on application switch

**Date:** 2026-09-28
**Status:** Approved (design)

## Problem

Today the layout badge (`layout-tooltip.ahk`) appears only when the keyboard layout
changes *within the same window* (`LT_Poll` deliberately ignores foreground changes:
`changed := (hwnd = LT_lastHwnd) && ...`). Switching to another application that happens
to use a different layout shows nothing — the user starts typing blind until they notice
the tray icon.

**Goal:** show the badge whenever focus lands on a text input field in a newly focused
window, even when the layout did not change.

## Requirements

1. Badge appears when the foreground window changes and the new window has a text caret
   (input field) — **always**, regardless of whether the layout differs from the last one.
2. Badge does **not** appear when switching to a window without an input field (no mouse
   fallback for this trigger; existing mouse fallback for layout changes is unchanged).
3. Existing behaviour is unchanged:
   - layout change within the same window still shows the badge (with mouse fallback);
   - first poll after script start shows nothing (`LT_lastHwnd = 0` guard);
   - the badge still waits for Alt/Win to be physically released (Alt+Tab: badge appears
     after the switch completes, not during it);
   - unknown layout (`LT_ActiveHkl` returns 0) still shows nothing.

## Design

Single approach (chosen over WinEvent hook / separate timer — see Decision log):
extend the existing poll loop.

### New configuration flag

In the Configuration block of `layout-tooltip.ahk`:

```autohotkey
global LT_SHOW_ON_SWITCH := true   ; show the badge when switching to a window with an input field
```

### `LT_Trigger(hkl := 0, requireCaret := false)`

New optional parameter, forwarded to `LT_Show`. The app-switch path calls
`LT_Trigger(0, true)` — layout and caret are resolved at show time.

### `LT_Show(hkl := 0, requireCaret := false)`

- Existing Alt/Win release wait is preserved and must carry `requireCaret` through the
  retry (`SetTimer(LT_Show.Bind(hkl, requireCaret), -20)`).
- After the caret lookup:
  - `requireCaret` and no caret found → return without showing (no mouse fallback);
  - `requireCaret = false` (ordinary layout change) → behaviour unchanged, including the
    mouse-pointer fallback.
- `LT_MAX_LOOKUP` guard unchanged: slow first lookup in a freshly started app still
  skips the badge.

### `LT_Poll`

```autohotkey
switched := (hwnd != LT_lastHwnd) && LT_lastHwnd       ; foreground window changed (skip first poll)
changed  := (hwnd = LT_lastHwnd) && (hkl != LT_lastHkl) && LT_lastHkl
LT_lastHwnd := hwnd, LT_lastHkl := hkl
if changed
    LT_Trigger(hkl)
else if switched && LT_SHOW_ON_SWITCH
    LT_Trigger(0, true)    ; layout + caret resolved at show time
```

The two conditions are mutually exclusive (one requires same window, the other a
different one), so a window switch can never also fire the layout-change badge.

### Edge cases (already handled by construction)

| Case | Behaviour |
|---|---|
| First poll after start (`LT_lastHwnd = 0`) | no badge |
| Rapid Alt+Tab through several windows | each switch re-arms the show timer; badge renders for the final window |
| Layout change in the same window | unchanged (separate, mutually exclusive condition) |
| Focus moves to a field within the same window (no hwnd change) | no badge — out of scope (app switch only) |
| New window has no readable layout | no badge (unchanged `LT_ActiveHkl` guard) |

## Testing

Manual, on Windows 10/11:

1. **Alt+Tab into Notepad** (or another text editor) with a caret → badge appears showing
   the current layout, even if it equals the previously shown one.
2. **Alt+Tab into a window without an input field** (File Explorer folder view, Settings
   with a button focused) → no badge.
3. **Layout change within the same window** (Ctrl+Space / Alt+Shift / tray click) → badge
   as before, including the mouse fallback when there is no caret.
4. **F13 force-show** (standalone test hotkey) → still works.
5. **Alt+Tab while holding Alt** → badge appears after Alt is released, not during.
6. **Script start** → no badge from the first poll.

## Documentation

- Header comment of `layout-tooltip.ahk` (currently says "whenever the layout of the
  active window changes") — extend to mention the app-switch trigger.
- `README.md` — describe the new behaviour and the `LT_SHOW_ON_SWITCH` flag in the
  `layout-tooltip.ahk` configuration section.

## Out of scope

- WinEvent hook for instant foreground notification (latency of the 50 ms poll is
  imperceptible next to `LT_SHOW_DELAY`).
- Per-app layout memory (Windows has no such concept).
- Badge on focus change without window change.
- Changes to `layout-switch.ahk`.

## Decision log

- **Approach:** extend `LT_Poll` (option A). WinEvent hook (B) adds complexity for
  negligible latency gain; separate timer (C) is redundant since `LT_Poll` already runs
  every 50 ms.
- **Trigger condition:** show on every window switch with an input field ("always"),
  per user preference — not only when the layout differs.
- **No-fallback rule:** the app-switch trigger never falls back to the mouse pointer;
  a window without a caret shows nothing. User-confirmed.