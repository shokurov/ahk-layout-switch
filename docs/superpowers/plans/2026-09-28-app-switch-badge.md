# Layout Badge on Application Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the layout badge in `layout-tooltip.ahk` when focus lands on a text input field in a newly foregrounded window, even when the layout did not change.

**Architecture:** Extend the existing 50 ms poll loop (`LT_Poll`) to detect a foreground window change (`hwnd != LT_lastHwnd`) as a second trigger, next to the existing same-window layout-change trigger. The new trigger calls `LT_Trigger(0, true)` which routes through `LT_Show` with a new `requireCaret` flag: layout and caret are resolved at show time, and when `requireCaret` is set, a missing caret suppresses the badge entirely (no mouse-pointer fallback). A new config flag `LT_SHOW_ON_SWITCH` gates the behaviour.

**Tech Stack:** AutoHotkey v2.0, Win32 (GetGUIThreadInfo / MSAA / UIA caret lookup — all existing). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-28-app-switch-badge-design.md`

## Global Constraints

- AutoHotkey v2.0 (`#Requires AutoHotkey v2.0` already in the file).
- All code changes confined to `layout-tooltip.ahk`. `layout-switch.ahk` and `lib/UIA.ahk` must not change.
- Existing behaviour must be preserved bit-for-bit for `requireCaret = false` paths (layout change in same window, mouse fallback, F13 force-show, modifier wait).
- The two poll conditions must stay mutually exclusive: a window switch never fires the layout-change badge and vice versa.
- `LT_Show`'s existing Alt/Win release wait must carry the `requireCaret` flag through its retry.
- The mouse-pointer fallback applies ONLY to `requireCaret = false` (ordinary layout changes). A window switch to a caret-less window shows nothing.

---

### Task 1: Core trigger logic in `layout-tooltip.ahk`

**Files:**
- Modify: `layout-tooltip.ahk:45` (config block, add `LT_SHOW_ON_SWITCH`)
- Modify: `layout-tooltip.ahk:313-322` (`LT_Poll`)
- Modify: `layout-tooltip.ahk:330-332` (`LT_Trigger`)
- Modify: `layout-tooltip.ahk:350-385` (`LT_Show`)

**Interfaces:**
- Consumes: existing `LT_ActiveHkl(&hwnd)` → HKL (0 on failure), `LT_GetCaret(&x,&y,&w,&h)` → bool, `LT_Trigger`, `LT_Show`, `LT_MODIFIER_WAIT`, `LT_SHOW_ON_SWITCH` (new).
- Produces:
  - `LT_Trigger(hkl := 0, requireCaret := false)` — new optional param.
  - `LT_Show(hkl := 0, requireCaret := false)` — new optional param; when true, missing caret ⇒ no badge.
  - `global LT_SHOW_ON_SWITCH := true` — config flag.

- [ ] **Step 1: Add the config flag**

In `layout-tooltip.ahk`, in the Configuration block, after the `LT_MODIFIER_WAIT` line (currently line 45), add:

```autohotkey
global LT_SHOW_ON_SWITCH := true   ; show the badge when switching to a window with an input field
```

- [ ] **Step 2: Extend `LT_Poll` with the window-switch trigger**

Replace the body of `LT_Poll` (currently lines 313-322):

```autohotkey
LT_Poll() {
    global LT_lastHwnd, LT_lastHkl
    hkl := LT_ActiveHkl(&hwnd)
    if !hkl
        return
    switched := (hwnd != LT_lastHwnd) && LT_lastHwnd       ; foreground window changed (skip first poll)
    changed  := (hwnd = LT_lastHwnd) && (hkl != LT_lastHkl) && LT_lastHkl
    LT_lastHwnd := hwnd, LT_lastHkl := hkl
    if changed
        LT_Trigger(hkl)
    else if switched && LT_SHOW_ON_SWITCH
        LT_Trigger(0, true)    ; layout + caret resolved at show time
}
```

- [ ] **Step 3: Add `requireCaret` to `LT_Trigger`**

Replace the current `LT_Trigger` (lines 330-332):

```autohotkey
LT_Trigger(hkl := 0, requireCaret := false) {
    SetTimer(LT_Show.Bind(hkl, requireCaret), -LT_SHOW_DELAY)
}
```

- [ ] **Step 4: Add `requireCaret` to `LT_Show` and suppress the mouse fallback**

In `LT_Show` (starts line 350):

a) Change the signature (line 350) and the modifier-wait retry (line 356):

```autohotkey
LT_Show(hkl := 0, requireCaret := false) {
    global LT_visible, LT_lastHkl
    static waited := 0
    if (GetKeyState("Alt", "P") || GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) {
        if (waited < LT_MODIFIER_WAIT) {
            waited += 20
            SetTimer(LT_Show.Bind(hkl, requireCaret), -20)
            return
        }
    }
```

b) Replace the caret-lookup block (currently lines 370-378):

```autohotkey
    ; A slow first lookup (accessibility tree being built in the target process) means it's
    ; too late to be useful — show nothing. No caret at all (Warp, games, GPU-rendered UIs…)
    ; falls back to the mouse pointer — unless the show was requested for a window switch,
    ; where a missing caret means "no input field" and the badge is skipped entirely.
    t := A_TickCount
    found := LT_GetCaret(&x, &y, &w, &h)
    if (A_TickCount - t > LT_MAX_LOOKUP)
        return
    if !found {
        if requireCaret
            return
        LT_MouseAnchor(&x, &y, &w, &h)
    }
```

- [ ] **Step 5: Verify the full changed functions**

Read `layout-tooltip.ahk` lines 306-385 and confirm:

- `LT_Poll` has the `switched`/`changed` pair from Step 2;
- `LT_Trigger` signature is `LT_Trigger(hkl := 0, requireCaret := false)`;
- `LT_Show` signature is `LT_Show(hkl := 0, requireCaret := false)`, its retry passes `requireCaret`, and the `if !found` block returns early when `requireCaret` is true;
- the standalone hotkey `F13:: LT_Trigger()` (line 653) still compiles (default params).

- [ ] **Step 6: Manual verification**

Run the script standalone (double-click or `AutoHotkey layout-tooltip.ahk`). Expected:

| # | Action | Expected |
|---|---|---|
| 1 | Alt+Tab into Notepad, focus in the text area | Badge appears showing the current layout, even if it equals the previously shown one |
| 2 | Alt+Tab into a window without an input field (e.g. File Explorer folder view with no selection, desktop) | No badge |
| 3 | Switch layout in the same window (Ctrl+Space / Alt+Shift / tray click) | Badge as before, including the mouse fallback in a caret-less window |
| 4 | Press F13 (standalone test hotkey) | Badge appears (mouse fallback path unchanged) |
| 5 | Alt+Tab while holding Alt | Badge appears after Alt is released, not during |
| 6 | Freshly start the script | No badge from the first poll |

- [ ] **Step 7: Commit**

```bash
git add layout-tooltip.ahk
git commit -m "feat(tooltip): show the badge when switching to a window with an input field"
```

---

### Task 2: Documentation

**Files:**
- Modify: `layout-tooltip.ahk:2-4` (header comment)
- Modify: `README.md` (tooltip description + configuration section)

**Interfaces:**
- Consumes: `LT_SHOW_ON_SWITCH` (Task 1).

- [ ] **Step 1: Update the file header comment**

Replace the header comment in `layout-tooltip.ahk` (currently lines 3-4):

```autohotkey
; layout-tooltip.ahk — show a small badge with the keyboard-layout code ("EN"/"DE"…)
; right under the text caret whenever the layout of the active window changes
; (Ctrl+Space, Win+Space, Alt+Shift, mouse click on the tray indicator — any source),
; and when switching to another window whose focus lands on a text input field
; (LT_SHOW_ON_SWITCH).
```

- [ ] **Step 2: Update the README tooltip description**

In `README.md`, update the `layout-tooltip.ahk` row of the table:

```markdown
| `layout-tooltip.ahk` | Shows the layout code (`EN`, `DE`, …) in a small badge right under the text caret every time the keyboard layout changes — and whenever you switch to a window whose focus lands on a text input field. The Windows counterpart of macOS' *Show input source indicator near the caret*. |
```

- [ ] **Step 3: Document the flag in the README configuration section**

In `README.md`, in the `layout-tooltip.ahk` configuration block, after the paragraph ending "…The badge also waits until Alt and Win are physically released (`LT_MODIFIER_WAIT` caps the wait at 2 s): Chromium and Electron apps treat a window that appears while Alt is held as a lone Alt press and would open their menu bar when you let go.", append:

```markdown
Switching to a window whose focus lands on a text input field also shows the badge for
the current layout, even if it did not change. Turn that off with `LT_SHOW_ON_SWITCH :=
false`. Windows without an input field never show the badge from this trigger.
```

- [ ] **Step 4: Verify**

- `grep -n "LT_SHOW_ON_SWITCH" layout-tooltip.ahk README.md` returns the config flag, the header-comment mention, and the README mention.
- The README table row for `layout-tooltip.ahk` no longer says "every time the keyboard layout changes" as the only trigger.

- [ ] **Step 5: Commit**

```bash
git add layout-tooltip.ahk README.md
git commit -m "docs: document the app-switch badge trigger"
```

---

## Self-Review

**Spec coverage:**
- Config flag `LT_SHOW_ON_SWITCH` → Task 1 Step 1. ✅
- `LT_Trigger`/`LT_Show` `requireCaret` param → Task 1 Steps 3-4. ✅
- No mouse fallback on switch trigger → Task 1 Step 4b. ✅
- Modifier wait carries the flag → Task 1 Step 4a. ✅
- `LT_Poll` mutual-exclusive triggers + first-poll guard → Task 1 Step 2. ✅
- Edge cases (rapid Alt+Tab, same-window layout change, unknown layout) → covered by existing structure, verified in Task 1 Step 6. ✅
- Documentation → Task 2. ✅

**Placeholder scan:** No TBD/TODO; every step has exact code or exact verification instructions.

**Type/signature consistency:** `requireCaret` is consistently a `:= false` defaulted bool across `LT_Trigger`, `LT_Show`, and the `.Bind(hkl, requireCaret)` call in both the initial timer and the modifier-wait retry. `LT_SHOW_ON_SWITCH` referenced identically in `LT_Poll` and the docs.