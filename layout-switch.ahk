#Requires AutoHotkey v2.0
; layout-switch.ahk — switch keyboard layouts the way you are used to on the other OS.
;
; Cycles through a configured list of languages with one hotkey (macOS-style Ctrl+Space
; by default) and optionally jumps straight to a language with a dedicated hotkey. Only the
; languages listed below take part in cycling; any other layouts installed in Windows are
; skipped. Switching applies to the active window, exactly like Windows' own switching.
;
; Standalone: run this file directly. As a module: #Include it and call
; Layout.Cycle(["EN", "DE"]) / Layout.Set("DE") from your own hotkeys.

#SingleInstance force

; ============================================================================ Configuration

; Languages to cycle through, in order: two-letter ISO 639 codes as Windows reports them
; (EN, DE, FR, RU, …). A language must be installed in Windows to be selectable.
global Languages := ["EN", "DE"]

; Hotkey that moves to the next language in the list. AutoHotkey syntax:
; ^ Ctrl, ! Alt, + Shift, # Win. Examples: "^Space" (macOS style), "!Space", "CapsLock".
global CycleHotkey := "^Space"

; Optional hotkeys that select one language directly. Use Map() to disable.
; Example below: Ctrl+Shift+1 -> EN, Ctrl+Shift+2 -> DE.
global DirectHotkeys := Map("^+1", "EN", "^+2", "DE")

; ============================================================================ End of configuration

if (A_ScriptName = "layout-switch.ahk") {   ; standalone: register the configured hotkeys
    Hotkey(CycleHotkey, (*) => Layout.Cycle(Languages))
    for key, lang in DirectHotkeys
        Hotkey(key, ((l, *) => Layout.Set(l)).Bind(lang))
}

; Layout — installed keyboard layouts and per-window switching. All methods are static.
;
; A layout is addressed by its two-letter language code ("EN"); Windows identifies it by an
; HKL handle whose low word is the language ID. Switching posts WM_INPUTLANGCHANGEREQUEST to
; the active window's root owner, the same message the Win+Space / Alt+Shift handlers send,
; so every application reacts exactly as it does to the system hotkeys. The lParam must be
; a real HKL — the HKL_NEXT sentinel makes some applications hang.
class Layout {
    static WM_INPUTLANGCHANGEREQUEST := 0x50
    static GA_ROOTOWNER := 3
    static LOCALE_SISO639LANGNAME := 0x59

    ; Layout.List — installed layouts as an Array of {hkl, code}, in system order.
    static List() {
        n := DllCall("GetKeyboardLayoutList", "Int", 0, "Ptr", 0, "Int")
        buf := Buffer(n * A_PtrSize, 0)
        n := DllCall("GetKeyboardLayoutList", "Int", n, "Ptr", buf, "Int")
        list := []
        loop n {
            hkl := NumGet(buf, (A_Index - 1) * A_PtrSize, "Ptr")
            list.Push({hkl: hkl, code: Layout.Code(hkl)})
        }
        return list
    }

    ; Layout.Code — upper-case ISO 639 code ("EN") for an HKL, or "" if unknown.
    static Code(hkl) {
        buf := Buffer(20, 0)
        if DllCall("GetLocaleInfoW", "UInt", hkl & 0xFFFF, "UInt", Layout.LOCALE_SISO639LANGNAME, "Ptr", buf, "Int", 10)
            return StrUpper(StrGet(buf, "UTF-16"))
        return ""
    }

    ; Layout.Current — HKL of the window that has keyboard focus (0 if none / unknown).
    ; Uses the focused control's thread when there is one: more accurate than the
    ; foreground window's thread for hosted controls (UWP frames, WebView…).
    static Current(&hwnd := 0) {
        hwnd := WinExist("A")
        if !hwnd
            return 0
        size := 8 + 6 * A_PtrSize + 16
        gti := Buffer(size, 0), NumPut("UInt", size, gti)
        focus := DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gti) ? NumGet(gti, 8 + A_PtrSize, "Ptr") : 0
        tid := DllCall("GetWindowThreadProcessId", "Ptr", focus ? focus : hwnd, "Ptr", 0, "UInt")
        return DllCall("GetKeyboardLayout", "UInt", tid, "Ptr")
    }

    ; Layout.Set — switch the active window to the first installed layout whose language
    ; code is `code`. Returns true on success, false if no such layout is installed.
    static Set(code, hwnd := 0) {
        for l in Layout.List()
            if (l.code = code)
                return Layout.SetHkl(l.hkl, hwnd)
        return false
    }

    ; Layout.SetHkl — switch the active (or given) window to a specific HKL.
    static SetHkl(hkl, hwnd := 0) {
        if !hwnd
            hwnd := WinExist("A")
        if !hwnd
            return false
        target := DllCall("GetAncestor", "Ptr", hwnd, "UInt", Layout.GA_ROOTOWNER, "Ptr")
        PostMessage(Layout.WM_INPUTLANGCHANGEREQUEST, 0, hkl,, "ahk_id " (target ? target : hwnd))
        return true
    }

    ; Layout.Cycle — move to the next language in `codes` (wraps around). If the current
    ; language is not in the list, or can't be read (classic console), the first one is set.
    static Cycle(codes) {
        current := Layout.Code(Layout.Current())
        next := codes[1]
        for i, code in codes
            if (code = current) {
                next := codes[i = codes.Length ? 1 : i + 1]
                break
            }
        Layout.Set(next)
        ; An Alt-based hotkey leaves Alt-up to the application, which many treat as "open
        ; the menu bar"; a harmless F15 in between prevents that.
        if InStr(A_ThisHotkey, "!")
            Send("{Blind}{F15}")
    }
}
