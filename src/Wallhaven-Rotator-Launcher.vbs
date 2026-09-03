Option Explicit

Dim shell, fso, baseDir, scriptPath, mode, extra, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "Wallhaven-Wallpaper-Tray.ps1")

mode = "autostart"
If WScript.Arguments.Count > 0 Then
    mode = LCase(WScript.Arguments(0))
End If

extra = " -Autostart"
If mode = "show" Then
    extra = ""
End If

cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & extra

' 0 = fenêtre cachée ; False = ne pas attendre la fin.
shell.Run cmd, 0, False
