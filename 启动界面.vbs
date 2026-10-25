Option Explicit

Dim shell, fso, projectDir, pwshPath, guiPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

projectDir = fso.GetParentFolderName(WScript.ScriptFullName)
pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
guiPath = fso.BuildPath(projectDir, "extract-gui.ps1")

If Not fso.FileExists(pwshPath) Then
    MsgBox "PowerShell 7 was not found:" & vbCrLf & pwshPath, vbCritical, "Launcher error"
    WScript.Quit 1
End If

If Not fso.FileExists(guiPath) Then
    MsgBox "GUI script was not found:" & vbCrLf & guiPath, vbCritical, "Launcher error"
    WScript.Quit 1
End If

command = Chr(34) & pwshPath & Chr(34) & _
    " -Sta -NoProfile -ExecutionPolicy Bypass -File " & _
    Chr(34) & guiPath & Chr(34) & " -HideConsole"

' The GUI script hides only its console after the WinForms window is prepared.
shell.Run command, 1, False
