param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'verification.ps1')
$artifacts = Join-Path $root 'artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null

function Invoke-NativeCheck {
	param([string]$Program, [string[]]$Arguments, [int]$TimeoutMs = 30000, [string]$Log)
	$info = [System.Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $Program
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
	$process = [System.Diagnostics.Process]::new()
	$process.StartInfo = $info
	try {
		if (-not $process.Start()) { throw "Cannot start $Program" }
		$stdout = $process.StandardOutput.ReadToEndAsync()
		$stderr = $process.StandardError.ReadToEndAsync()
		if (-not $process.WaitForExit($TimeoutMs)) {
			$process.Kill($true)
			throw "Check timed out: $Program $($Arguments -join ' ')"
		}
		$output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
		if ($Log) { [System.IO.File]::WriteAllText($Log, $output) }
		if ($process.ExitCode -ne 0) { throw "Check failed ($($process.ExitCode)): $Program`n$output" }
	} finally { $process.Dispose() }
}

if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1') -Tests }
$app = Join-Path $root 'dist\DisplayMind.exe'
$tests = Join-Path $root 'dist\DisplayMind.Tests.exe'
$coreReport = Join-Path $artifacts 'core-tests.json'
$uiReport = Join-Path $artifacts 'ui-tests.json'
Invoke-NativeCheck -Program $tests -Arguments @('--report', $coreReport) -TimeoutMs 45000 -Log (Join-Path $artifacts 'core-tests.log')
Invoke-NativeCheck -Program $app -Arguments @('--ui-self-test', $uiReport) -TimeoutMs 30000

$screens = @(
	@('presets'), @('editor', '--editor'), @('sound', '--editor', '--sound'),
	@('wireless', '--editor', '--wireless'), @('rules', '--rules'),
	@('rule-editor', '--rule-editor'), @('empty', '--empty'),
	@('pending', '--pending'), @('unavailable', '--unavailable'),
	@('long', '--long'), @('many', '--many'), @('folders', '--folders'), @('filter', '--folders', '--filter')
)
$rendered = 0
foreach ($theme in @('light','dark')) {
	foreach ($screen in $screens) {
		$name = "$($screen[0])-$theme.png"
		$arguments = @('--render-preview', (Join-Path $artifacts $name), "--$theme")
		if ($screen.Count -gt 1) { $arguments += $screen[1..($screen.Count-1)] }
		Invoke-NativeCheck -Program $app -Arguments $arguments -TimeoutMs 15000
		$file = Get-Item -LiteralPath (Join-Path $artifacts $name)
		if ($file.Length -lt 5000) { throw "Preview looks incomplete: $name" }
		$rendered++
	}
}

$hardwarePath = Join-Path $artifacts 'hardware.json'
Invoke-NativeCheck -Program $app -Arguments @('--diagnostics', $hardwarePath) -TimeoutMs 15000
$hardware = Get-Content -LiteralPath $hardwarePath -Raw | ConvertFrom-Json
$core = Get-Content -LiteralPath $coreReport -Raw | ConvertFrom-Json
$ui = Get-Content -LiteralPath $uiReport -Raw | ConvertFrom-Json
if ($core.failed -or $ui.failed -or -not $hardware.readOnly) { throw 'Verification reports contain failures.' }
$driver = $hardware.displayConfigurationValidation
if ($driver -and -not $driver.succeeded -and -not $driver.blockedBySession) { throw "Driver validation rejected the plan: $($driver.message)" }
$summary = [ordered]@{
	version = (Get-Item -LiteralPath $app).VersionInfo.ProductVersion
	platform = 'windows-x64'
	verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
	executableSha256 = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash
	sourceSha256 = Get-DisplayMindSourceHash $root
	coreTestsPassed = $core.passed
	uiTestsPassed = $ui.passed
	testsFailed = $core.failed + $ui.failed
	previewScreensRendered = $rendered
	displaysDetected = @($hardware.displays).Count
	usbDevicesDetected = @($hardware.devices | Where-Object kind -eq 'usb').Count
	audioEndpointsDetected = @($hardware.audioDevices).Count
	readOnlyHardwareDiagnostics = $true
	displayPlanValidatedByWindows = [bool]$driver.succeeded
	displayValidationBlockedBySession = [bool]$driver.blockedBySession
	liveDisplayWritesDuringTests = 0
	liveAudioWritesDuringTests = 0
	liveMiracastConnectionsDuringTests = 0
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifacts 'verification.json') -Encoding utf8NoBOM
$summary | ConvertTo-Json
