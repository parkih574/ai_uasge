# build-exe.ps1 — AiUsageTray.exe 생성
#
# 트레이 앱 본체는 ai-usage-tray.ps1 이고, exe 는 콘솔 창 없이 그것을 띄우는 런처다.
# Windows 에 항상 있는 .NET Framework 컴파일러(csc.exe)만 쓴다 — 설치할 도구·모듈 없음.
# 사용: pwsh -File build-exe.ps1   (결과: 같은 폴더의 AiUsageTray.exe)

$ErrorActionPreference = 'Stop'

$csc = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '.NET Framework 4.x 컴파일러(csc.exe)를 찾지 못했습니다. Windows 기능에서 .NET Framework 4.8 을 켜세요.' }

$source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

// Launches ai-usage-tray.ps1 (sitting next to this exe) with no console window.
// PowerShell 7 is preferred; Windows PowerShell 5.1 is the fallback so the app
// runs on a stock Windows install with nothing else set up.
static class Launcher
{
    static readonly string[] PwshHosts =
    {
        @"%ProgramFiles%\PowerShell\7\pwsh.exe",
        @"%ProgramW6432%\PowerShell\7\pwsh.exe",
    };

    static string FindOnPath(string name)
    {
        string value = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string raw in value.Split(Path.PathSeparator))
        {
            string dir = raw.Trim().Trim('"');
            if (dir.Length == 0) continue;
            try
            {
                string candidate = Path.Combine(dir, name);
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        return null;
    }

    static string FindHost()
    {
        foreach (string candidate in PwshHosts)
        {
            string path = Environment.ExpandEnvironmentVariables(candidate);
            if (File.Exists(path)) return path;
        }
        string fromPath = FindOnPath("pwsh.exe");
        if (fromPath != null) return fromPath;
        string storeAlias = Environment.ExpandEnvironmentVariables(
            @"%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe");
        if (File.Exists(storeAlias)) return storeAlias;
        string windowsPowerShell = Environment.ExpandEnvironmentVariables(
            @"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(windowsPowerShell)) return windowsPowerShell;
        return "powershell.exe"; // let PATH resolve it as a last resort
    }

    static string Quote(string value)
    {
        return value.IndexOf(' ') >= 0 ? "\"" + value + "\"" : value;
    }

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "ai-usage-tray.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "ai-usage-tray.ps1 not found next to AiUsageTray.exe.\nKeep the exe in the project folder.",
                "AI Usage Tray", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        StringBuilder cmd = new StringBuilder();
        cmd.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(script));
        foreach (string arg in args) cmd.Append(' ').Append(Quote(arg));

        ProcessStartInfo psi = new ProcessStartInfo(FindHost(), cmd.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;

        try
        {
            using (Process process = Process.Start(psi))
            {
                bool waitForSelfTest = false;
                foreach (string arg in args)
                {
                    if (String.Equals(arg, "-SyntheticSelfTest", StringComparison.OrdinalIgnoreCase))
                        waitForSelfTest = true;
                }
                if (waitForSelfTest) process.WaitForExit();
                if (waitForSelfTest || process.WaitForExit(750))
                {
                    int exitCode = process.ExitCode;
                    if (exitCode != 0)
                    {
                        MessageBox.Show("AI Usage Tray stopped during startup.",
                            "AI Usage Tray", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    return exitCode;
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("Failed to start PowerShell:\n" + ex.Message,
                "AI Usage Tray", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }
}
'@

$id = [guid]::NewGuid().ToString('N')
$cs = Join-Path ([System.IO.Path]::GetTempPath()) "AiUsageTrayLauncher.$id.cs"
$exe = Join-Path $PSScriptRoot 'AiUsageTray.exe'
$tempExe = Join-Path $PSScriptRoot ".AiUsageTray.$id.tmp.exe"
$backupExe = Join-Path $PSScriptRoot ".AiUsageTray.$id.bak.exe"
Set-Content -LiteralPath $cs -Value $source -Encoding UTF8
try {
    & $csc /nologo /target:winexe /platform:anycpu /optimize+ /r:System.Windows.Forms.dll "/out:$tempExe" $cs
    if ($LASTEXITCODE -ne 0) { throw "컴파일 실패 (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $tempExe)) { throw '컴파일 결과 파일이 없습니다' }
    if (Test-Path -LiteralPath $exe) { [System.IO.File]::Replace($tempExe, $exe, $backupExe) }
    else { [System.IO.File]::Move($tempExe, $exe) }
}
finally {
    Remove-Item -LiteralPath $cs -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupExe -Force -ErrorAction SilentlyContinue
}

"built: $exe"
