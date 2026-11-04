#Requires AutoHotkey v2.0
; Update-UltraTax.ahk - Standalone UltraTax CS updater worker
; Usage: AutoHotkey64.exe Update-UltraTax.ahk <Year> <ExecutablePath>
; Exit codes:
;   0 = Success (No updates needed OR Updates successfully applied)
;   1 = Error / Timeout / Execution failure

#include Lib\UIA.ahk

SetTitleMatchMode(2)
CoordMode("ToolTip", "Screen")

LogMsg(msg) {
    line := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . " [AHK] " . msg . "`r`n"
    try FileAppend(line, "*")
    try {
        logDir := "C:\ProgramData\GoldenImageUpdater\Logs"
        if (!DirExist(logDir))
            DirCreate(logDir)
        FileAppend(line, logDir . "\AutoHotkey-UltraTax.log")
    }
}

if (A_Args.Length < 2) {
    LogMsg("ERROR: Missing arguments. Expected: Update-UltraTax.ahk <Year> <ExecutablePath>")
    ExitApp(1)
}

targetYear := A_Args[1]
targetExe  := A_Args[2]

LogMsg("Target Tax Year: " . targetYear . ", Executable: " . targetExe)

if (!FileExist(targetExe)) {
    LogMsg("ERROR: Executable not found at path: " . targetExe)
    ExitApp(1)
}

; --- Helper: Dismiss Popups & Bulletins ---
HandleBulletins(loops := 5) {
    loop loops {
        Sleep(1000)

        if WinExist("Choose Data Location") {
            LogMsg("Detected 'Choose Data Location' popup; clicking OK.")
            try WinActivate("Choose Data Location")
            try {
                UIA.ElementFromHandle("Choose Data Location").FindElement({ Name: "OK", Type: "Button" }).Click()
            } catch {
                Send("{Enter}")
            }
        }

        if WinExist("User already present") {
            LogMsg("Detected 'User already present' popup; clicking OK.")
            try WinActivate("User already present")
            try {
                UIA.ElementFromHandle("User already present").FindElement({ Name: "OK", Type: "Button" }).Click()
            } catch {
                Send("{Enter}")
            }
        }

        if WinExist("User Bulletin") {
            LogMsg("Detected 'User Bulletin' popup; dismissing.")
            try WinActivate("User Bulletin")
            try {
                UIA.ElementFromHandle("User Bulletin").FindElement({ Name: "Close", Type: "Button" }).Click()
            } catch {
                WinClose("User Bulletin")
            }
        }
    }
}

; --- Helper: TR / Onvio Login Flow ---
TRLogin() {
    if WinWait("Sign In | Firm ID", , 12) {
        LogMsg("Detected 'Sign In | Firm ID' window; attempting Sign In button.")
        try WinActivate("Sign In | Firm ID")
        Sleep(1500)
        try {
            UIA.ElementFromHandle("Sign In | Firm ID").WaitElement({ AutomationId: "SignInButton" }, 10000).ControlClick()
        } catch {
            ; ignore
        }

        GroupAdd("TRLoginGroup", "Onvio")
        GroupAdd("TRLoginGroup", "Sign in to")

        if WinWait("ahk_group TRLoginGroup", , 25) {
            if WinExist("Onvio") {
                LogMsg("Detected Onvio authenticated session.")
                Sleep(3000)
                try WinClose("Onvio")
                return
            }
        }
    }
}

; ==============================================================================
; Main Update Execution Flow
; ==============================================================================
try {
    LogMsg("Launching UltraTax CS: " . targetExe)
    Run(targetExe)

    ; Check for Thomson Reuters sign-in / Onvio window
    TRLogin()

    LogMsg("Waiting for UltraTax CS main window...")
    if !WinWait("UltraTax CS", , 120) {
        LogMsg("ERROR: Timed out waiting for UltraTax CS main window (120s).")
        ExitApp(1)
    }

    try WinActivate("UltraTax CS")
    try WinMaximize("UltraTax CS")
    Sleep(1000)

    HandleBulletins(5)

    ; Navigate to CS Connect
    LogMsg("Searching for CS Connect button...")
    btn := ""
    loop 60 { ; Check up to 120 seconds (2s sleep)
        HandleBulletins(1)

        try {
            if WinExist("UltraTax CS") {
                utEl := UIA.ElementFromHandle("UltraTax CS")
                btn := utEl.FindElement({ Name: "CS Connect (Ctrl+K)", Type: "Button" })
                if btn {
                    LogMsg("Found 'CS Connect (Ctrl+K)' button; clicking.")
                    btn.Click()
                    break
                }
            }
        } catch {
            ; continue polling
        }

        Sleep(2000)
    }

    ; Fallback to Ctrl+K shortcut if button search timed out
    if (!btn) {
        LogMsg("Button not found via UIA; sending fallback shortcut Ctrl+K.")
        try WinActivate("UltraTax CS")
        Sleep(500)
        Send("^k")
    }

    ; Wait for CS Connect dialog
    LogMsg("Waiting for CS Connect window...")
    if !WinWait("CS Connect", , 120) {
        LogMsg("ERROR: Timed out waiting for CS Connect window (120s).")
        ExitApp(1)
    }

    LogMsg("CS Connect opened; clicking Connect.")
    try {
        UIA.ElementFromHandle("CS Connect").WaitElement({ Name: "Connect", Type: "Button" }, 15000).Click()
    } catch {
        try WinActivate("CS Connect")
        Sleep(500)
        Send("{Enter}")
    }

    ; Wait for Call Summary (up to 5 minutes)
    LogMsg("Waiting for Call Summary window (up to 300s)...")
    if !WinWait("Call Summary", , 300) {
        LogMsg("ERROR: Timed out waiting for Call Summary window.")
        ExitApp(1)
    }

    Sleep(2000)
    docText := ""
    try {
        callSumEl := UIA.ElementFromHandle("Call Summary")
        docText := callSumEl.WaitElement({ LocalizedType: "document", Type: "Document" }, 15000).Value
    } catch as err {
        LogMsg("WARNING: Could not read Document element from Call Summary: " . err.Message)
    }

    LogMsg("Call Summary content preview: " . SubStr(docText, 1, 150))

    ; Case A: No updates found
    if (InStr(docText, "No new updates") || InStr(docText, "no updates")) {
        LogMsg("STATUS: NO_UPDATES - UltraTax " . targetYear . " is already up to date.")
        try callSumEl.FindElement({ Name: "Close", Type: "Button" }).Click()
        Sleep(1000)
        try WinClose("UltraTax CS")
        ExitApp(0)
    }

    ; Case B: Updates applied (restart required)
    LogMsg("STATUS: UPDATES_FOUND - Applying updates...")
    try callSumEl.FindElement({ Name: "Close", Type: "Button" }).Click()

    LogMsg("Waiting for 'Updates have been applied' restart prompt...")
    if WinWait("UltraTax CS", "Updates have been applied", 60) {
        LogMsg("Restart prompt appeared; clicking OK.")
        try {
            UIA.ElementFromHandle("UltraTax CS").WaitElement({ Name: "OK", Type: "Button" }, 10000).Click()
        } catch {
            Send("{Enter}")
        }

        ; Wait for restart cycle
        LogMsg("Waiting for UltraTax CS restart cycle...")
        WinWaitClose("UltraTax CS", , 60)
        if WinWait("UltraTax CS", , 120) {
            try WinActivate("UltraTax CS")
            HandleBulletins(10)
            try WinClose("UltraTax CS")
        }
    } else {
        LogMsg("No restart prompt; closing UltraTax CS.")
        try WinClose("UltraTax CS")
    }

    LogMsg("STATUS: UPDATES_INSTALLED - UltraTax " . targetYear . " successfully updated.")
    ExitApp(0)

} catch as err {
    LogMsg("FATAL ERROR: " . err.Message . " (Line " . err.Line . ")")
    ExitApp(1)
}
