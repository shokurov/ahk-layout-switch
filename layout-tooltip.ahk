#Requires AutoHotkey v2.0
; layout-tooltip.ahk — show a small badge with the keyboard-layout code ("EN"/"DE"…)
; right under the text caret whenever the layout of the active window changes
; (Ctrl+Space, Win+Space, Alt+Shift, mouse click on the tray indicator — any source).
; The Windows counterpart of macOS' "Show input source indicator near the caret".
;
; Caret position is resolved through regular, documented APIs only:
;   1. GetGUIThreadInfo (classic Win32 caret: Notepad, Explorer, Office, Sublime, WinForms…)
;   2. MSAA OBJID_CARET asked from the window itself (Chromium/Electron: Edge, VS Code, Telegram…)
;   3. UI Automation TextPattern selection range (WinUI/UWP, Windows Terminal, Win+S search)
; No caret found: the badge is shown under the mouse pointer instead. Lookup slower than
; LT_MAX_LOOKUP: nothing is shown.
; The badge window itself uses one undocumented call (CreateWindowInBand) so it can appear
; over Win+S / Start menu — see LT_Init.
;
; Standalone: run this file directly. As a module: #Include it from your main script
; (lib\UIA.ahk is included once; AHK v2 ignores repeated #Include of the same file).

#Include lib\UIA.ahk

; ============================================================================ Configuration

; Languages: language ID (low word of the HKL, see
; https://learn.microsoft.com/windows/win32/intl/language-identifier-constants-and-strings)
; -> [badge label, colour]. Colour is a shade of the system accent palette: "light3",
; "light2", "light1", "accent", "dark1", "dark2", "dark3", "complement" (the accent with its
; hue rotated by 180°, e.g. orange for a blue accent), or a literal "RRGGBB".
; The palette is one hue in eight lightness steps, so the second language gets
; "complement" to be clearly different at a glance. Text colour follows the background.
; Languages not listed here get their ISO 639 code (LT_IsoCode) and LT_OTHER_SHADE.
global LT_LANG := Map(
    0x0409, ["EN", "accent"],       ; English (US)
    0x0407, ["DE", "complement"],   ; German
    ; 0x0419, ["RU", "dark3"],      ; Russian
    ; 0x040C, ["FR", "light2"],     ; French
)
global LT_OTHER_SHADE := "dark2"

global LT_SHOW_DELAY     := 50    ; ms after a layout change before the badge appears
global LT_HIDE_DELAY     := 300   ; ms the badge stays visible
global LT_FOLLOW_TICK    := 30    ; ms between caret re-position while visible
global LT_POLL_TICK      := 50    ; ms between layout polls
global LT_CARET_GAP      := 4     ; px gap between caret bottom and badge
global LT_MAX_LOOKUP     := 100   ; ms; if finding the caret took longer, it's too late — show nothing

; ============================================================================ End of configuration

global LT_STANDALONE     := (A_ScriptName = "layout-tooltip.ahk")
global LT_FALLBACK := Map("light3", "99EBFF", "light2", "4CC2FF", "light1", "0091F8", "accent", "0078D4"
                        , "dark1", "0067C0", "dark2", "003E92", "dark3", "001A68")

; LT_AccentPalette — read the system accent palette.
;
; Windows' accent palette: HKCU\...\Explorer\Accent\AccentPalette is 8 RGBA entries
; (light3, light2, light1, accent, dark1, dark2, dark3, spare) — the same shades Settings
; shows and the shell uses. Re-read on every show so a theme change is picked up.
;
; Returns: Map shade-name -> "RRGGBB" for light3…dark3 plus "complement" (accent hue
;          rotated 180°). Falls back to LT_FALLBACK when the registry value is missing.
LT_AccentPalette() {
    static names := ["light3", "light2", "light1", "accent", "dark1", "dark2", "dark3"]
    pal := Map()
    try {
        hex := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentPalette")
        for i, n in names
            pal[n] := SubStr(hex, (i - 1) * 8 + 1, 6)   ; RRGGBB, skip alpha byte
    } catch
        pal := LT_FALLBACK.Clone()
    pal["complement"] := LT_RotateHue(pal["accent"], 180)
    return pal
}

; LT_RotateHue — rotate the hue of a colour (HSL round trip), keeping saturation and
; lightness so the result sits at the same visual weight as the source.
;
; Params:  hex  "RRGGBB"
;          deg  rotation in degrees (180 = complementary colour)
; Returns: "RRGGBB"; a grey input is returned unchanged (no hue to rotate).
LT_RotateHue(hex, deg) {
    r := Integer("0x" SubStr(hex, 1, 2)) / 255, g := Integer("0x" SubStr(hex, 3, 2)) / 255, b := Integer("0x" SubStr(hex, 5, 2)) / 255
    mx := Max(r, g, b), mn := Min(r, g, b), l := (mx + mn) / 2, d := mx - mn
    if (d = 0)
        return hex   ; grey has no hue
    s := l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    if (mx = r)
        h := Mod((g - b) / d + (g < b ? 6 : 0), 6)
    else if (mx = g)
        h := (b - r) / d + 2
    else
        h := (r - g) / d + 4
    h := Mod(h * 60 + deg, 360) / 360
    q := l < 0.5 ? l * (1 + s) : l + s - l * s, p := 2 * l - q
    ch(t) {
        t := Mod(t + 1, 1)
        if (t < 1 / 6)
            return p + (q - p) * 6 * t
        if (t < 1 / 2)
            return q
        if (t < 2 / 3)
            return p + (q - p) * (2 / 3 - t) * 6
        return p
    }
    return Format("{:02X}{:02X}{:02X}", Round(ch(h + 1 / 3) * 255), Round(ch(h) * 255), Round(ch(h - 1 / 3) * 255))
}

global LT_hwnd := 0        ; the badge window (raw HWND, not a Gui — see LT_Init)
global LT_inBand := false  ; true when the window lives in the system-tools z-band
global LT_w := 0, LT_h := 0
global LT_lastHwnd := 0
global LT_lastHkl := 0
global LT_visible := false

; AutoHotkey is system-DPI-aware: on a monitor with a different scale factor every
; coordinate it sees is virtualised, and the badge drifts away from the caret in
; proportion to X. Per-monitor awareness (v2) makes all coordinates physical pixels.
; Must run before the window is created.
DllCall("SetThreadDpiAwarenessContext", "Ptr", -4)  ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2

LT_Init()

; LT_Init — create the (hidden) badge window and start the layout poll. Runs once at load.
;
; The badge is a layered popup window whose bitmap we paint with GDI (UpdateLayeredWindow).
; Reason for not using an AutoHotkey Gui: Win+S / Start menu / notification centre live in
; z-band 6 (ZBID_IMMERSIVE_MOGO), above every AlwaysOnTop window (band 1). The only way to
; draw over them is the undocumented user32!CreateWindowInBand with band 16
; (ZBID_SYSTEM_TOOLS), which a normal process is allowed to use — and such a window can't
; host a band-1 child, so an AHK Gui can't be re-parented into it. If the function is
; missing or refuses, the same code runs on a plain CreateWindowEx window (band 1).
;
; Sets:    LT_hwnd (window handle), LT_inBand (true when band 16 succeeded).
LT_Init() {
    global LT_hwnd, LT_inBand
    static WS_POPUP := 0x80000000
    ; WS_EX_TOPMOST 8 | WS_EX_TOOLWINDOW 0x80 | WS_EX_TRANSPARENT 0x20 (click-through)
    ; | WS_EX_LAYERED 0x80000 | WS_EX_NOACTIVATE 0x08000000
    exStyle := 0x8 | 0x80 | 0x20 | 0x80000 | 0x08000000
    pCreate := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", "user32", "Ptr"), "AStr", "CreateWindowInBand", "Ptr")
    if pCreate {
        LT_hwnd := DllCall(pCreate, "UInt", exStyle, "Str", "Static", "Str", "", "UInt", WS_POPUP
            , "Int", 0, "Int", 0, "Int", 10, "Int", 10, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 16, "Ptr")
        LT_inBand := !!LT_hwnd
    }
    if !LT_hwnd
        LT_hwnd := DllCall("CreateWindowExW", "UInt", exStyle, "Str", "Static", "Str", "", "UInt", WS_POPUP
            , "Int", 0, "Int", 0, "Int", 10, "Int", 10, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    ; Windows 11: let DWM round the corners (DWMWA_WINDOW_CORNER_PREFERENCE = 33,
    ; DWMWCP_ROUNDSMALL = 3). Harmless no-op on older builds.
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", LT_hwnd, "UInt", 33, "UInt*", 3, "UInt", 4)
    SetTimer(LT_Poll, LT_POLL_TICK)
}

; LT_Render — paint the badge bitmap and push it to the layered window.
;
; Draws `text` (Segoe UI bold 10pt, colour from LT_TextColor) centred on a solid
; `colorHex` background into a 32-bit DIB, then hands it to UpdateLayeredWindow, which
; also moves the window to (x, y). Font size and padding scale with the DPI of the
; monitor that contains (x, y). Does not show the window.
;
; Params:  text      label to draw ("EN", "RU", …)
;          colorHex  background "RRGGBB"
;          x, y      screen position of the badge's top-left corner, physical pixels
; Sets:    LT_w, LT_h — resulting badge size, used by LT_Reposition for clamping.
LT_Render(text, colorHex, x, y) {
    global LT_w, LT_h
    static padX := 7, padY := 2
    dpi := 96
    hMon := DllCall("MonitorFromPoint", "Int64", (y << 32) | (x & 0xFFFFFFFF), "UInt", 2, "Ptr")
    if (DllCall("shcore\GetDpiForMonitor", "Ptr", hMon, "UInt", 0, "UInt*", &mdpi := 0, "UInt*", &_ := 0) = 0 && mdpi)
        dpi := mdpi
    scale := dpi / 96
    ; font: Segoe UI bold 10pt
    hFont := DllCall("CreateFontW", "Int", -Round(10 * dpi / 72), "Int", 0, "Int", 0, "Int", 0, "Int", 700
        , "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0, "Str", "Segoe UI", "Ptr")
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    oldFont := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    rc := Buffer(16, 0)
    DllCall("DrawTextW", "Ptr", hdc, "Str", text, "Int", -1, "Ptr", rc, "UInt", 0x400)  ; DT_CALCRECT
    tw := NumGet(rc, 8, "Int"), th := NumGet(rc, 12, "Int")
    w := Max(tw, Round(28 * scale)) + Round(2 * padX * scale), h := th + Round(2 * padY * scale)
    ; 32-bit DIB to draw into
    bi := Buffer(40, 0)
    NumPut("UInt", 40, "Int", w, "Int", -h, "UShort", 1, "UShort", 32, bi)
    hBmp := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", bi, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    oldBmp := DllCall("SelectObject", "Ptr", hdc, "Ptr", hBmp, "Ptr")
    r := Integer("0x" SubStr(colorHex, 1, 2)), g := Integer("0x" SubStr(colorHex, 3, 2)), b := Integer("0x" SubStr(colorHex, 5, 2))
    hBrush := DllCall("CreateSolidBrush", "UInt", (b << 16) | (g << 8) | r, "Ptr")
    NumPut("Int", 0, "Int", 0, "Int", w, "Int", h, rc)
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", hBrush)
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)  ; TRANSPARENT
    DllCall("SetTextColor", "Ptr", hdc, "UInt", LT_TextColor(r, g, b))
    DllCall("DrawTextW", "Ptr", hdc, "Str", text, "Int", -1, "Ptr", rc, "UInt", 0x1 | 0x4 | 0x20)  ; CENTER|VCENTER|SINGLELINE
    ; push to screen: constant alpha 255, per-pixel alpha ignored (AC_SRC_ALPHA not set)
    ptDst := Buffer(8), NumPut("Int", x, "Int", y, ptDst)
    size := Buffer(8), NumPut("Int", w, "Int", h, size)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4), NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 0, blend)
    DllCall("UpdateLayeredWindow", "Ptr", LT_hwnd, "Ptr", 0, "Ptr", ptDst, "Ptr", size, "Ptr", hdc, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)  ; ULW_ALPHA
    DllCall("SelectObject", "Ptr", hdc, "Ptr", oldBmp), DllCall("SelectObject", "Ptr", hdc, "Ptr", oldFont)
    DllCall("DeleteObject", "Ptr", hBmp), DllCall("DeleteObject", "Ptr", hBrush), DllCall("DeleteObject", "Ptr", hFont)
    DllCall("DeleteDC", "Ptr", hdc)
    LT_w := w, LT_h := h
}

; ---------------------------------------------------------------- layout polling

; LT_ActiveHkl — keyboard layout of the window that currently has keyboard focus.
;
; Params:  &hwnd  receives the active (foreground) window handle, 0 if none
; Returns: HKL handle (language ID in the low word), or 0 when there is no active window
;          or the layout can't be determined.
LT_ActiveHkl(&hwnd) {
    hwnd := WinExist("A")
    if !hwnd
        return 0
    ; Use the thread that owns keyboard focus when available — more accurate than the
    ; foreground window's thread for hosted controls (UWP frames, WebView, etc.).
    gti := LT_GuiThreadInfo()
    focus := gti ? NumGet(gti, 8 + A_PtrSize, "Ptr") : 0
    tid := DllCall("GetWindowThreadProcessId", "Ptr", focus ? focus : hwnd, "UInt*", &pid := 0, "UInt")
    hkl := DllCall("GetKeyboardLayout", "UInt", tid, "Ptr")
    if (!hkl && WinGetClass(hwnd) = "ConsoleWindowClass")
        hkl := LT_ConsoleHkl(hwnd, pid)
    return hkl
}

; LT_ConsoleHkl — keyboard layout of a classic console window (ConsoleWindowClass).
;
; A classic console window reports the *client* process (cmd/powershell) as its owner,
; and that thread has no message queue, so GetKeyboardLayout returns 0. The layout lives
; on the message thread of the hosting conhost.exe, which is either the client's parent
; or its child. Find that thread with Toolhelp once per console window and cache it: the
; snapshot walks every thread in the system and can take hundreds of ms.
;
; Params:  hwnd       console window handle (cache key)
;          clientPid  process ID the window reports (the console client)
; Returns: HKL of the conhost message thread, or 0 if no host thread was found.
LT_ConsoleHkl(hwnd, clientPid) {
    static cache := Map()   ; hwnd -> conhost thread id
    if cache.Has(hwnd) {
        if (hkl := DllCall("GetKeyboardLayout", "UInt", cache[hwnd], "Ptr"))
            return hkl
        cache.Delete(hwnd)  ; thread gone — window was re-hosted or is closing
    }
    if (tid := LT_ConsoleHostThread(clientPid)) {
        cache[hwnd] := tid
        return DllCall("GetKeyboardLayout", "UInt", tid, "Ptr")
    }
    return 0
}

; LT_ConsoleHostThread — find the conhost.exe thread that owns a console client's window.
;
; Takes a Toolhelp process snapshot to locate the conhost.exe that is either the parent or
; a child of `clientPid`, then a thread snapshot to find the first thread of that conhost
; which has a keyboard layout (i.e. its message thread). Expensive: walks every process
; and thread in the system — callers must cache the result.
;
; Params:  clientPid  process ID of the console client (cmd, powershell, …)
; Returns: thread ID, or 0 if no matching conhost/thread exists.
LT_ConsoleHostThread(clientPid) {
    static TH32CS_SNAPPROCESS := 2, TH32CS_SNAPTHREAD := 4
    static PE_SIZE := (A_PtrSize = 8) ? 568 : 556, PE_PARENT := (A_PtrSize = 8) ? 32 : 24, PE_EXE := (A_PtrSize = 8) ? 44 : 36
    snap := DllCall("CreateToolhelp32Snapshot", "UInt", TH32CS_SNAPPROCESS, "UInt", 0, "Ptr")
    if (snap = -1)
        return 0
    pe := Buffer(PE_SIZE, 0), NumPut("UInt", PE_SIZE, pe)
    clientParent := 0, conhosts := []
    if DllCall("Process32FirstW", "Ptr", snap, "Ptr", pe) {
        loop {
            pid := NumGet(pe, 8, "UInt"), parent := NumGet(pe, PE_PARENT, "UInt")
            if (pid = clientPid)
                clientParent := parent
            else if (StrGet(pe.Ptr + PE_EXE, "UTF-16") = "conhost.exe")
                conhosts.Push([pid, parent])
        } until !DllCall("Process32NextW", "Ptr", snap, "Ptr", pe)
    }
    DllCall("CloseHandle", "Ptr", snap)
    hostPid := 0
    for c in conhosts
        if (c[2] = clientPid || c[1] = clientParent) {
            hostPid := c[1]
            break
        }
    if !hostPid
        return 0
    snap := DllCall("CreateToolhelp32Snapshot", "UInt", TH32CS_SNAPTHREAD, "UInt", 0, "Ptr")
    if (snap = -1)
        return 0
    te := Buffer(28, 0), NumPut("UInt", 28, te)
    found := 0
    if DllCall("Thread32First", "Ptr", snap, "Ptr", te) {
        loop {
            tid := NumGet(te, 8, "UInt")
            if (NumGet(te, 12, "UInt") = hostPid && DllCall("GetKeyboardLayout", "UInt", tid, "Ptr")) {
                found := tid
                break
            }
        } until !DllCall("Thread32Next", "Ptr", snap, "Ptr", te)
    }
    DllCall("CloseHandle", "Ptr", snap)
    return found
}

; LT_Poll — timer callback (every LT_POLL_TICK ms) that detects layout changes.
;
; Compares the active window's layout with the previous poll. Only a change *within the
; same window* counts: switching to another window that happens to use a different layout
; is not a layout switch and shows nothing. On change, schedules the badge via LT_Trigger.
;
; Sets:    LT_lastHwnd, LT_lastHkl.
LT_Poll() {
    global LT_lastHwnd, LT_lastHkl
    hkl := LT_ActiveHkl(&hwnd)
    if !hkl
        return
    changed := (hwnd = LT_lastHwnd) && (hkl != LT_lastHkl) && LT_lastHkl
    LT_lastHwnd := hwnd, LT_lastHkl := hkl
    if changed
        LT_Trigger(hkl)
}

; LT_Trigger — schedule the badge to appear after LT_SHOW_DELAY ms.
;
; Public entry: call it right after a manual switch (e.g. from the Alt+Space hotkey) to
; skip the poll latency. The poll calls it too.
;
; Params:  hkl  layout to display; 0 = read the active window's layout at show time
LT_Trigger(hkl := 0) {
    SetTimer(LT_Show.Bind(hkl), -LT_SHOW_DELAY)
}

; ---------------------------------------------------------------- show / hide

; LT_Show — render and show the badge for a layout, then start follow/hide timers.
;
; Resolves label and colour for `hkl`, finds the caret (or the mouse pointer as
; fallback), paints the badge under it and shows the window without activating it.
; Repeated calls while visible simply re-render and restart the hide timer.
;
; Params:  hkl  layout to display; 0 = current layout of the active window
; Sets:    LT_visible, LT_lastHkl.
LT_Show(hkl := 0) {
    global LT_visible, LT_lastHkl
    if !hkl
        hkl := LT_ActiveHkl(&_)
    LT_lastHkl := hkl
    langId := hkl & 0xFFFF
    info := LT_LANG.Has(langId) ? LT_LANG[langId] : [LT_IsoCode(langId), LT_OTHER_SHADE]
    pal := LT_AccentPalette()
    color := pal.Has(info[2]) ? pal[info[2]]
           : (info[2] ~= "^[0-9A-Fa-f]{6}$") ? info[2]      ; literal RRGGBB
           : LT_FALLBACK["accent"]
    ; A slow first lookup (accessibility tree being built in the target process) means it's
    ; too late to be useful — show nothing. No caret at all (Warp, games, GPU-rendered UIs…)
    ; falls back to the mouse pointer.
    t := A_TickCount
    found := LT_GetCaret(&x, &y, &w, &h)
    if (A_TickCount - t > LT_MAX_LOOKUP)
        return
    if !found
        LT_MouseAnchor(&x, &y, &w, &h)
    LT_Render(info[1], color, x, y + h + LT_CARET_GAP)
    LT_Reposition(x, y, w, h)
    DllCall("ShowWindow", "Ptr", LT_hwnd, "Int", 8)  ; SW_SHOWNA
    LT_visible := true
    SetTimer(LT_Follow, LT_FOLLOW_TICK)
    SetTimer(LT_Hide, -LT_HIDE_DELAY)
}

; LT_Hide — hide the badge and stop following the caret. Timer callback (LT_HIDE_DELAY).
LT_Hide() {
    global LT_visible
    SetTimer(LT_Follow, 0)
    DllCall("ShowWindow", "Ptr", LT_hwnd, "Int", 0)  ; SW_HIDE
    LT_visible := false
}

; LT_Follow — timer callback (every LT_FOLLOW_TICK ms while visible) that keeps the badge
; glued to the caret, or to the mouse pointer when there is no caret.
LT_Follow() {
    if !LT_visible
        return
    if !LT_GetCaret(&x, &y, &w, &h)
        LT_MouseAnchor(&x, &y, &w, &h)
    LT_Reposition(x, y, w, h)
}

; LT_MouseAnchor — pseudo-caret rectangle at the mouse pointer (fallback anchor).
;
; The badge ends up just below and to the right of the arrow's hotspot, like a tooltip.
;
; Params:  &x, &y, &w, &h  receive the anchor rect in physical screen pixels
LT_MouseAnchor(&x, &y, &w, &h) {
    pt := Buffer(8), DllCall("GetCursorPos", "Ptr", pt)   ; physical pixels, any monitor
    x := NumGet(pt, 0, "Int") + 12, y := NumGet(pt, 4, "Int"), w := 1, h := 16
}

; LT_Reposition — move the badge under an anchor rect, clamped to that monitor.
;
; The badge's top-left goes to (x, y + h + LT_CARET_GAP) and is pushed back inside the
; monitor containing that point so it never straddles a screen edge. Skips the
; SetWindowPos call when the position hasn't changed since the last call.
;
; Params:  x, y, w, h  anchor rect (caret or mouse) in physical screen pixels
LT_Reposition(x, y, w, h) {
    static lastX := -1, lastY := -1
    bx := x, by := y + h + LT_CARET_GAP
    ; keep on the monitor the caret is on
    MonitorGet(LT_MonitorFromPoint(bx, by), &mL, &mT, &mR, &mB)
    bx := Min(Max(bx, mL), mR - LT_w)
    by := Min(Max(by, mT), mB - LT_h)
    if (bx != lastX || by != lastY) {
        ; SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE — a layered window keeps its bitmap when moved
        DllCall("SetWindowPos", "Ptr", LT_hwnd, "Ptr", 0, "Int", bx, "Int", by, "Int", 0, "Int", 0, "UInt", 0x1 | 0x4 | 0x10)
        lastX := bx, lastY := by
    }
}

; LT_TextColor — pick a readable text colour for a background.
;
; White on dark shades, near-black on light ones. Threshold on relative luminance
; (sRGB weights), the same rule WinUI uses.
;
; Params:  r, g, b  background components 0–255
; Returns: COLORREF (0x00BBGGRR); both results are greys so byte order doesn't matter.
LT_TextColor(r, g, b) {
    lum := (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    return lum > 0.55 ? 0x1A1A1A : 0xFFFFFF   ; COLORREF is 0x00BBGGRR; both are grey
}

; LT_GetPos — current screen rectangle of the badge window (for tests / callers).
;
; Params:  &x, &y, &w, &h  receive position and size in physical screen pixels
LT_GetPos(&x, &y, &w, &h) {
    rc := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", LT_hwnd, "Ptr", rc)
    x := NumGet(rc, 0, "Int"), y := NumGet(rc, 4, "Int")
    w := NumGet(rc, 8, "Int") - x, h := NumGet(rc, 12, "Int") - y
}

; LT_MonitorFromPoint — AutoHotkey monitor number (1-based, as used by MonitorGet)
; containing a screen point; the primary monitor if the point is off every screen.
;
; Params:  x, y  physical screen pixels
; Returns: monitor index for MonitorGet / MonitorGetWorkArea.
LT_MonitorFromPoint(x, y) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return A_Index
    }
    return MonitorGetPrimary()
}

; LT_IsoCode — label for a language that has no entry in LT_LANG.
;
; Params:  langId  language identifier (low word of an HKL, e.g. 0x0407)
; Returns: upper-case ISO 639 code ("DE", "FR", …), or the ID as 4 hex digits if the
;          locale is unknown to the system.
LT_IsoCode(langId) {
    buf := Buffer(20, 0)
    if DllCall("GetLocaleInfoW", "UInt", langId, "UInt", 0x59, "Ptr", buf, "Int", 10)  ; LOCALE_SISO639LANGNAME
        return StrUpper(StrGet(buf, "UTF-16"))
    return Format("{:04X}", langId)
}

; ---------------------------------------------------------------- caret lookup

; LT_GetCaret — locate the text caret of the focused control.
;
; Tries the cheapest source first: GetGUIThreadInfo (Win32 caret), then the window's own
; MSAA caret object (Chromium/Electron), then UI Automation TextPattern (WinUI, Windows
; Terminal, Win+S). Each source is skipped silently when it doesn't apply.
;
; Params:  &x, &y, &w, &h  receive the caret rect in physical screen pixels
; Returns: true if any source found a caret, false otherwise (outputs are then 0).
LT_GetCaret(&x, &y, &w, &h) {
    x := y := w := h := 0
    if LT_CaretFromGuiThreadInfo(&x, &y, &w, &h)
        return true
    if LT_CaretFromMsaa(&x, &y, &w, &h)
        return true
    if LT_CaretFromUia(&x, &y, &w, &h)
        return true
    return false
}

; LT_GuiThreadInfo — GUITHREADINFO of the foreground thread (GetGUIThreadInfo(0)).
;
; Returns: Buffer with the filled structure, or 0 on failure. Layout (offsets depend on
;          A_PtrSize): cbSize, flags, hwndActive, hwndFocus (8 + A_PtrSize),
;          hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret (8 + 5*A_PtrSize),
;          RECT rcCaret (8 + 6*A_PtrSize, client coords of hwndCaret).
LT_GuiThreadInfo() {
    size := 8 + 6 * A_PtrSize + 16
    gti := Buffer(size, 0)
    NumPut("UInt", size, gti, 0)
    return DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gti) ? gti : 0
}

; LT_CaretFromGuiThreadInfo — caret source 1: the classic Win32 caret.
;
; Works for controls that call CreateCaret/SetCaretPos: Notepad, Explorer, Office,
; Sublime, WinForms, conhost. Converts rcCaret from client to screen coordinates.
;
; Params:  &x, &y, &w, &h  receive the caret rect in physical screen pixels
; Returns: true on success; false when the foreground thread has no caret window or the
;          rect is empty.
LT_CaretFromGuiThreadInfo(&x, &y, &w, &h) {
    gti := LT_GuiThreadInfo()
    if !gti
        return false
    hwndCaret := NumGet(gti, 8 + 5 * A_PtrSize, "Ptr")
    if !hwndCaret
        return false
    off := 8 + 6 * A_PtrSize
    l := NumGet(gti, off, "Int"), t := NumGet(gti, off + 4, "Int")
    r := NumGet(gti, off + 8, "Int"), b := NumGet(gti, off + 12, "Int")
    if (r <= l && b <= t)
        return false
    pt := Buffer(8), NumPut("Int", l, "Int", t, pt)
    DllCall("ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int"), w := r - l, h := b - t
    return true
}

; LT_CaretFromMsaa — caret source 2: the focused window's own MSAA caret object.
;
; Chromium and Electron apps (Edge, Chrome, VS Code, Telegram, Slack…) answer
; WM_GETOBJECT/OBJID_CARET with an IAccessible whose accLocation is the caret rect.
; Windows that don't answer are skipped — see the comment inside for why
; AccessibleObjectFromWindow must not be used as a substitute.
;
; Params:  &x, &y, &w, &h  receive the caret rect in physical screen pixels
; Returns: true on success; false when the window has no caret object, the call fails or
;          the reported rect is empty.
LT_CaretFromMsaa(&x, &y, &w, &h) {
    static IID_IAccessible := LT_Guid("{618736E0-3C3D-11CF-810C-00AA00389B71}")
    static OBJID_CARET := 0xFFFFFFF8
    gti := LT_GuiThreadInfo()
    hwnd := gti ? NumGet(gti, 8 + A_PtrSize, "Ptr") : 0   ; hwndFocus
    if !hwnd
        hwnd := WinExist("A")
    if !hwnd
        return false
    ; Ask the window itself for its caret object (WM_GETOBJECT / OBJID_CARET) instead of
    ; AccessibleObjectFromWindow: when the app doesn't answer, the latter substitutes
    ; oleacc's built-in caret object, and calling that crashes with an uncatchable
    ; access violation (reproduced on conhost and Win11 Notepad). Apps that do answer
    ; (Chromium, Electron) are safe.
    static WM_GETOBJECT := 0x3D, SMTO_ABORTIFHUNG := 2
    if !DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", WM_GETOBJECT, "Ptr", 0, "Ptr", -8, "UInt", SMTO_ABORTIFHUNG, "UInt", 50, "Ptr*", &lres := 0)
        return false
    if !lres
        return false
    if DllCall("oleacc\ObjectFromLresult", "Ptr", lres, "Ptr", IID_IAccessible, "Ptr", 0, "Ptr*", &pacc := 0) != 0 || !pacc
        return false
    ; IAccessible::accLocation is vtable slot 22 (IUnknown 3 + IDispatch 4 + 15 accessors).
    ; varChild is a VARIANT passed by value: on x64 a >8-byte struct goes in by pointer,
    ; on x86 it is pushed as four 32-bit words.
    varChild := Buffer(16, 0), NumPut("UShort", 3, varChild)   ; VT_I4, lVal = CHILDID_SELF
    cx := cy := cw := ch := 0
    try {
        if (A_PtrSize = 8)
            ComCall(22, pacc, "Int*", &cx, "Int*", &cy, "Int*", &cw, "Int*", &ch, "Ptr", varChild)
        else
            ComCall(22, pacc, "Int*", &cx, "Int*", &cy, "Int*", &cw, "Int*", &ch, "Int", 3, "Int", 0, "Int", 0, "Int", 0)
    } catch {
        ObjRelease(pacc)
        return false
    }
    ObjRelease(pacc)
    if (cw = 0 && ch = 0)
        return false
    x := cx, y := cy, w := cw, h := ch
    return true
}

; LT_CaretFromUia — caret source 3: UI Automation TextPattern of the focused element.
;
; The selection range of a text control is degenerate (empty) at the caret; its bounding
; rect, or that of the enclosing character when the range has none, gives the caret.
; Covers WinUI/UWP controls, Windows Terminal and the Win+S search box. The first call
; into a process may be slow while its accessibility tree is built (LT_Show guards
; against that with LT_MAX_LOOKUP).
;
; Params:  &x, &y, &w, &h  receive the caret rect in physical screen pixels (w is 1)
; Returns: true on success; false when the element has no TextPattern, no selection or
;          no rectangles, or any UIA call throws.
LT_CaretFromUia(&x, &y, &w, &h) {
    try {
        el := UIA.GetFocusedElement()
        ; check availability first: UIA.ahk throws from __New on a missing pattern and then
        ; its __Delete fails on the half-built object (error dialog even inside try)
        if !el.IsTextPatternAvailable
            return false
        tp := el.GetPattern(UIA.Pattern.Text)   ; not el.TextPattern: it tries Text2 first and blows up when absent
        sel := tp.GetSelection()
        if !sel.Length
            return false
        rng := sel[1]
        rects := rng.GetBoundingRectangles()
        if !rects.Length {
            ; degenerate (caret-only) ranges often have no rect — expand to one character
            rng := rng.Clone()
            rng.ExpandToEnclosingUnit(UIA.TextUnit.Character)
            rects := rng.GetBoundingRectangles()
            if !rects.Length
                return false
            rc := rects[1]
            x := rc.x, y := rc.y, w := 1, h := rc.h
            return true
        }
        rc := rects[rects.Length]           ; caret sits at the end of the selection
        x := rc.x + rc.w, y := rc.y, w := 1, h := rc.h
        return true
    } catch {
        return false
    }
}

; LT_Guid — parse a "{xxxxxxxx-xxxx-…}" string into a 16-byte GUID buffer for DllCall.
;
; Params:  str  GUID in registry format, braces included
; Returns: Buffer(16) holding the binary GUID.
LT_Guid(str) {
    buf := Buffer(16)
    DllCall("ole32\CLSIDFromString", "WStr", str, "Ptr", buf)
    return buf
}

; ---------------------------------------------------------------- standalone helpers

#HotIf LT_STANDALONE
; F13: force-show for testing without switching layout
F13:: LT_Trigger()
#HotIf
