Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
exe = fso.BuildPath(root, "net\bin\Release\net10.0-windows\win-x64\publish\codex-usage-monitor.exe")
If Not fso.FileExists(exe) Then
    MsgBox "Published Codex usage monitor not found:" & vbCrLf & exe & vbCrLf & "Run publish-monitor.ps1 first.", 16, "Codex Usage Monitor"
    WScript.Quit 1
End If
shell.Run """" & exe & """ -Widget", 0, False
