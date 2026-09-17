' Hidden launcher for ai-usage-tray.ps1 (no console window).
' Resolves both the script and the PowerShell host relative to this file / this machine,
' so it works from any install location. AiUsageTray.exe does the same thing natively.
Option Explicit
Dim sh, fso, here, script, exe, candidates, i, fromPath
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "ai-usage-tray.ps1")
If Not fso.FileExists(script) Then
    MsgBox "ai-usage-tray.ps1 not found next to this launcher.", 16, "AI Usage Tray"
    WScript.Quit 1
End If

' PowerShell 7 first (fixed installs, then PATH), Windows PowerShell 5.1 last.
candidates = Array( _
    sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe", _
    sh.ExpandEnvironmentStrings("%ProgramW6432%") & "\PowerShell\7\pwsh.exe")
exe = ""
For i = 0 To UBound(candidates)
    If exe = "" And fso.FileExists(candidates(i)) Then exe = candidates(i)
Next
If exe = "" Then
    fromPath = FindOnPath("pwsh.exe")
    If fromPath <> "" Then exe = fromPath
End If
If exe = "" Then
    fromPath = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe"
    If fso.FileExists(fromPath) Then exe = fromPath
End If
If exe = "" Then
    fromPath = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
    If fso.FileExists(fromPath) Then exe = fromPath
End If
If exe = "" Then exe = "powershell.exe"

If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "--self-test" Then
        WScript.Echo exe
        WScript.Quit 0
    End If
End If

sh.Run """" & exe & """ -NoProfile -ExecutionPolicy Bypass -File """ & script & """", 0, False

Function FindOnPath(fileName)
    Dim entries, entry, candidate, j
    entries = Split(sh.ExpandEnvironmentStrings("%PATH%"), ";")
    FindOnPath = ""
    For j = 0 To UBound(entries)
        entry = Trim(entries(j))
        If Len(entry) >= 2 And Left(entry, 1) = """" And Right(entry, 1) = """" Then
            entry = Mid(entry, 2, Len(entry) - 2)
        End If
        If Len(entry) > 0 Then
            candidate = fso.BuildPath(entry, fileName)
            If fso.FileExists(candidate) Then
                FindOnPath = candidate
                Exit Function
            End If
        End If
    Next
End Function
