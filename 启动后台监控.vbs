Option Explicit
' Start campus-network auto-auth monitor hidden (no console window).
Dim fso, sh, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Wscript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\autologin.ps1"" -Mode monitor"
sh.Run cmd, 0, False
WScript.Echo "Monitor started (hidden). Log: logs\autologin.log"