#Requires AutoHotkey v2.0
; Update-UltraTax.ahk - Standalone UltraTax CS updater worker via csiupd.exe update
; Usage: AutoHotkey64.exe Update-UltraTax.ahk <Year> <ExecutablePath>
; Exit codes:
;   0 = Success (No updates needed OR Updates successfully applied)
;   1 = Error / Timeout / Execution failure
;   2 = Deferred / Blocked by active users in UltraTax

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

isCsiUpd := InStr(targetExe, "csiupd.exe")

try {
    if (isCsiUpd) {
        LogMsg("Launching standalone CS Connect updater: " . targetExe . " update")
        Run('"' . targetExe . '" update')
    } else {
        LogMsg("Launching UltraTax CS application wrapper: " . targetExe)
        Run(targetExe)
    }

    ; Main monitoring loop (up to 20 minutes)
    maxLoops := 400
    loop maxLoops {
        Sleep(2500)

        ; ----------------------------------------------------------------------
        ; 1. Check for Active Users Dialog ("The following users are using UltraTax CS")
        ; ----------------------------------------------------------------------
        if WinExist("UltraTax CS - Apply Updates") {
            hwndApply := WinExist("UltraTax CS - Apply Updates")
            winText := WinGetText(hwndApply)

            if (InStr(winText, "following users are using") || InStr(winText, "need to exit")) {
                LogMsg("BLOCKED: Active users currently logged into UltraTax " . targetYear . ". Dismissing update dialog.")
                try {
                    UIA.ElementFromHandle(hwndApply).FindElement({ Name: "Cancel", Type: "Button" }).Click()
                } catch {
                    try ControlClick("Cancel", hwndApply)
                    catch {
                        WinClose(hwndApply)
                    }
                }
                Sleep(1000)
                ExitApp(2) ; Code 2 = Deferred due to active users
            }

            ; If it's an Apply Updates prompt without user locks (ready to apply)
            if (InStr(winText, "Apply") || InStr(winText, "ready to be applied") || InStr(winText, "Updates have been")) {
                LogMsg("Detected 'Apply Updates' prompt ready to install; clicking Apply/OK.")
                try {
                    UIA.ElementFromHandle(hwndApply).FindElement({ Name: "Apply", Type: "Button" }).Click()
                } catch {
                    try {
                        UIA.ElementFromHandle(hwndApply).FindElement({ Name: "OK", Type: "Button" }).Click()
                    } catch {
                        Send("{Enter}")
                    }
                }
            }
        }

        ; ----------------------------------------------------------------------
        ; 2. Check for CS Connect window
        ; ----------------------------------------------------------------------
        if WinExist("CS Connect") {
            hwndConn := WinExist("CS Connect")
            try {
                connEl := UIA.ElementFromHandle(hwndConn)
                btnConnect := connEl.FindElement({ Name: "Connect", Type: "Button" })
                if (btnConnect) {
                    LogMsg("Found CS Connect dialog; clicking Connect.")
                    btnConnect.Click()
                }
            } catch {
                ; If UIA fails, activate and press Enter
                try {
                    WinActivate(hwndConn)
                    Sleep(500)
                    Send("{Enter}")
                }
            }
        }

        ; ----------------------------------------------------------------------
        ; 3. Check for Call Summary window
        ; ----------------------------------------------------------------------
        if WinExist("Call Summary") {
            hwndSum := WinExist("Call Summary")
            Sleep(2000)
            docText := ""
            try {
                sumEl := UIA.ElementFromHandle(hwndSum)
                docText := sumEl.WaitElement({ LocalizedType: "document", Type: "Document" }, 8000).Value
            } catch as err {
                LogMsg("Call Summary document read notice: " . err.Message)
            }

            LogMsg("Call Summary content preview: " . SubStr(docText, 1, 150))

            if (InStr(docText, "No new updates") || InStr(docText, "no updates")) {
                LogMsg("STATUS: NO_UPDATES - UltraTax " . targetYear . " is already up to date.")
                try {
                    UIA.ElementFromHandle(hwndSum).FindElement({ Name: "Close", Type: "Button" }).Click()
                } catch {
                    try WinClose(hwndSum)
                }
                Sleep(1500)
                ExitApp(0)
            } else {
                LogMsg("STATUS: UPDATES_FOUND - UltraTax " . targetYear . " updates downloaded.")
                try {
                    UIA.ElementFromHandle(hwndSum).FindElement({ Name: "Close", Type: "Button" }).Click()
                } catch {
                    try WinClose(hwndSum)
                }
                Sleep(2000)
            }
        }

        ; ----------------------------------------------------------------------
        ; 4. Check for Restart / Completion Dialogs
        ; ----------------------------------------------------------------------
        if WinExist("UltraTax CS") {
            hwndUT := WinExist("UltraTax CS")
            winTextUT := WinGetText(hwndUT)

            if (InStr(winTextUT, "Updates have been applied") || InStr(winTextUT, "successfully applied") || InStr(winTextUT, "restart")) {
                LogMsg("Detected completion/restart prompt; clicking OK.")
                try {
                    UIA.ElementFromHandle(hwndUT).FindElement({ Name: "OK", Type: "Button" }).Click()
                } catch {
                    Send("{Enter}")
                }
                Sleep(3000)
                LogMsg("STATUS: UPDATES_INSTALLED - UltraTax " . targetYear . " update finished.")
                ExitApp(0)
            }
        }

        ; ----------------------------------------------------------------------
        ; 5. Process Exit Check
        ; ----------------------------------------------------------------------
        SplitPath(targetExe, &exeName)
        if (!ProcessExist(exeName)) {
            ; If process exited and no update windows remain
            if (!WinExist("UltraTax CS") && !WinExist("CS Connect") && !WinExist("Call Summary") && !WinExist("UltraTax CS - Apply Updates")) {
                LogMsg("Updater process " . exeName . " exited cleanly.")
                ExitApp(0)
            }
        }
    }

    LogMsg("TIMEOUT: Monitoring loop timed out after 20 minutes.")
    ExitApp(1)

} catch as err {
    LogMsg("FATAL ERROR: " . err.Message . " (Line " . err.Line . ")")
    ExitApp(1)
}
