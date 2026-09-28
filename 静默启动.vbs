' ============================================================
'  Silent launcher for the port monitor.
'
'  Starts server.ps1 with a hidden console window (style 0),
'  so nothing flashes on screen at logon.
'
'  Called by the Scheduled Task "PortMonitor-AutoStart".
'  You can also just double-click it - same effect.
' ============================================================
Option Explicit

Dim fso, sh, here, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ _
    & here & "\server.ps1"" --no-open"

' 0 = hidden window, False = do not wait for it to finish
sh.Run cmd, 0, False
