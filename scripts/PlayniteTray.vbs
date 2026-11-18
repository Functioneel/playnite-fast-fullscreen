' PlayniteTray.vbs - starts the tray helper with no console window flash.
' Used by the Startup shortcut so nothing appears at login.
Dim shell, fso, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\PlayniteTray.ps1""", 0, False
