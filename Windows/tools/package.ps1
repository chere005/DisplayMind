$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'verification.ps1')
$app = Join-Path $root 'dist\DisplayMind.exe'
$reportPath = Join-Path $root 'artifacts\verification.json'
if (-not (Test-Path -LiteralPath $reportPath)) { throw 'Run tools/preflight.ps1 before packaging.' }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.testsFailed -ne 0 -or (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash -ne $report.executableSha256) {
	throw 'The current executable has not passed preflight.'
}
if ($report.sourceSha256 -ne (Get-DisplayMindSourceHash $root)) { throw 'Source files changed after preflight. Rerun tools/preflight.ps1 before packaging.' }
$stage = Join-Path $root "artifacts\portable-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath $app -Destination (Join-Path $stage 'DisplayMind.exe') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $stage 'README.md') -Force
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $root) 'LICENSE') -Destination (Join-Path $stage 'LICENSE') -Force
Copy-Item -LiteralPath $reportPath -Destination (Join-Path $stage 'verification.json') -Force
$sourceRoot = Join-Path $stage 'source'
$windowsSource = Join-Path $sourceRoot 'Windows'
New-Item -ItemType Directory -Path $windowsSource -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $stage 'LICENSE') -Destination $sourceRoot
foreach ($inputPath in @('src','tests','tools','Resources','DisplayMind.vcxproj','DisplayMind.Tests.vcxproj','app.rc','app.manifest','README.md','SOURCE.json','AGENTS.md','.gitignore')) {
	Copy-Item -LiteralPath (Join-Path $root $inputPath) -Destination $windowsSource -Recurse
}
$zip = Join-Path $root "dist\DisplayMind-Windows-$($report.version)-x64.zip"
Compress-Archive -LiteralPath @((Join-Path $stage 'DisplayMind.exe'),(Join-Path $stage 'README.md'),(Join-Path $stage 'LICENSE'),(Join-Path $stage 'verification.json'),$sourceRoot) -DestinationPath $zip -Force
Get-FileHash -LiteralPath $zip -Algorithm SHA256
