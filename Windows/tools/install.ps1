param(
	[string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\DisplayMind'),
	[string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'DisplayMind'),
	[switch]$Launch
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dist\DisplayMind.exe'
$reportPath = Join-Path $root 'artifacts\verification.json'
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.testsFailed -ne 0 -or (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash -ne $report.executableSha256) {
	throw 'The executable has not passed preflight. Run tools/preflight.ps1.'
}
if ((Get-Item -LiteralPath $app).VersionInfo.ProductVersion -ne $report.version) { throw 'Executable and verification versions disagree.' }
$target = [System.IO.Path]::GetFullPath($InstallDirectory)
$data = [System.IO.Path]::GetFullPath($DataDirectory)
if ($target.TrimEnd('\') -eq [System.IO.Path]::GetPathRoot($target).TrimEnd('\') -or $target.TrimEnd('\') -eq $data.TrimEnd('\')) {
	throw 'Choose an application folder separate from the settings folder and drive root.'
}
function Assert-RecoveryIdle {
	if (Test-Path -LiteralPath (Join-Path $data 'pending-change.json')) { throw 'An apply or Revert is in progress. Its recovery journal was left intact.' }
	if (Test-Path -LiteralPath $data) {
		$recent = Get-ChildItem -LiteralPath $data -Filter 'restoring-*.json' -File | Where-Object LastWriteTimeUtc -gt ([DateTime]::UtcNow.AddMinutes(-3))
		if ($recent) { throw 'Recovery is in progress. Its snapshots were left intact.' }
	}
}
function Invoke-Diagnostics([string]$Program, [string]$ReportFile) {
	$info = [System.Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $Program; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
	$info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
	$info.ArgumentList.Add('--diagnostics'); $info.ArgumentList.Add($ReportFile)
	$process = [System.Diagnostics.Process]::Start($info)
	try {
		if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'Installed executable diagnostics timed out.' }
		if ($process.ExitCode -ne 0) { throw "Installed executable diagnostics failed ($($process.ExitCode))." }
	} finally { $process.Dispose() }
	$diagnostics = Get-Content -LiteralPath $ReportFile -Raw | ConvertFrom-Json
	if (-not $diagnostics.readOnly -or $diagnostics.version -ne $report.version) { throw 'Installed executable identity/read-only diagnostics failed.' }
}
Assert-RecoveryIdle
New-Item -ItemType Directory -Path $target -Force | Out-Null
$installedApp = Join-Path $target 'DisplayMind.exe'
$running = @(Get-Process -Name DisplayMind -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [System.IO.Path]::GetFullPath($_.Path) -eq $installedApp })
if ($running) {
	if (-not ('DisplayMindInstallerWindows' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DisplayMindInstallerWindows {
    public delegate bool Callback(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr state);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
}
'@
	}
	$processIds = @($running.Id)
	$callback = [DisplayMindInstallerWindows+Callback] {
		param($window, $state)
		[uint32]$windowProcess = 0
		[DisplayMindInstallerWindows]::GetWindowThreadProcessId($window, [ref]$windowProcess) | Out-Null
		if ($processIds -contains [int]$windowProcess) {
			# C_QUIT is shared by every released Windows version. Busy applications refuse it.
			[DisplayMindInstallerWindows]::PostMessage($window, 0x0111, [IntPtr]203, [IntPtr]::Zero) | Out-Null
		}
		return $true
	}
	[DisplayMindInstallerWindows]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
	foreach ($process in $running) { if (-not $process.WaitForExit(10000)) { throw 'DisplayMind is busy and refused to quit. The installed app was left intact.' } }
}
Assert-RecoveryIdle
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$backup = Join-Path $target "previous-$stamp"
$stage = Join-Path $target "update-$stamp"
New-Item -ItemType Directory -Path $stage,$backup -Force | Out-Null
$files = @('DisplayMind.exe','README.md','LICENSE','verification.json')
Copy-Item -LiteralPath $app -Destination (Join-Path $stage 'DisplayMind.exe')
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $stage 'README.md')
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $root) 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
Copy-Item -LiteralPath $reportPath -Destination (Join-Path $stage 'verification.json')
Invoke-Diagnostics (Join-Path $stage 'DisplayMind.exe') (Join-Path $stage 'diagnostics.json')
$replaced = @()
try {
	foreach ($name in $files) {
		$destination = Join-Path $target $name
		if (Test-Path -LiteralPath $destination) { Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $name) }
		Copy-Item -LiteralPath (Join-Path $stage $name) -Destination $destination -Force
		$replaced += $name
	}
	Invoke-Diagnostics $installedApp (Join-Path $stage 'installed-diagnostics.json')
	if ((Get-FileHash -LiteralPath $installedApp -Algorithm SHA256).Hash -ne $report.executableSha256) { throw 'Installed executable hash changed.' }
} catch {
	foreach ($name in $replaced) {
		$old = Join-Path $backup $name
		if (Test-Path -LiteralPath $old) { Copy-Item -LiteralPath $old -Destination (Join-Path $target $name) -Force }
		else { Remove-Item -LiteralPath (Join-Path $target $name) -Force }
	}
	throw
}
if ($Launch -or $running.Count) { Start-Process -FilePath $installedApp -ArgumentList '--background' -WorkingDirectory $target -WindowStyle Hidden }
[ordered]@{ version=$report.version; installedExecutable=$installedApp; previousFiles=$backup; diagnostics=(Join-Path $stage 'installed-diagnostics.json'); settingsPreserved=$data } | ConvertTo-Json
