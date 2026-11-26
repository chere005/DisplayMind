$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('DisplayMind-install-tests-' + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $temporary 'App'
$data = Join-Path $temporary 'Settings'
New-Item -ItemType Directory -Path $target,$data -Force | Out-Null
$sentinel = '{"preserve":"settings and recovery history"}'
[System.IO.File]::WriteAllText((Join-Path $data 'settings.json'), $sentinel)
[System.IO.File]::WriteAllText((Join-Path $data 'restoring-old.json'), $sentinel)
(Get-Item -LiteralPath (Join-Path $data 'restoring-old.json')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
[System.IO.File]::WriteAllText((Join-Path $target 'README.md'), 'previous version')
$report = & (Join-Path $PSScriptRoot 'install.ps1') -InstallDirectory $target -DataDirectory $data | ConvertFrom-Json
if ([System.IO.File]::ReadAllText((Join-Path $data 'settings.json')) -ne $sentinel -or [System.IO.File]::ReadAllText((Join-Path $data 'restoring-old.json')) -ne $sentinel) { throw 'Install changed user data.' }
if ([System.IO.File]::ReadAllText((Join-Path $report.previousFiles 'README.md')) -ne 'previous version') { throw 'Install did not preserve the prior app files.' }
$installedHash = (Get-FileHash -LiteralPath $report.installedExecutable).Hash
foreach ($journal in @('pending-change.json','restoring-active.json')) {
	$path = Join-Path $data $journal
	[System.IO.File]::WriteAllText($path, $sentinel)
	$rejected = $false
	try { & (Join-Path $PSScriptRoot 'install.ps1') -InstallDirectory $target -DataDirectory $data | Out-Null } catch { $rejected = $true }
	if (-not $rejected -or (Get-FileHash -LiteralPath $report.installedExecutable).Hash -ne $installedHash -or [System.IO.File]::ReadAllText($path) -ne $sentinel) { throw 'Active recovery was not protected.' }
	Remove-Item -LiteralPath $path
}
[ordered]@{ passed=3; failed=0; fixtureDirectory=$temporary; settingsPreserved=$true; priorInstallPreserved=$true; pendingRecoveryBlocked=$true; activeRecoveryBlocked=$true } | ConvertTo-Json
