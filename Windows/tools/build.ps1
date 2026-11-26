param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [switch]$Analyze, [switch]$Tests)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio 2022 C++ Build Tools with Windows 10/11 SDK are required.' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'Install the Desktop development with C++ workload.' }
$lockPath = Join-Path $root 'build.lock'
$lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
	& $msbuild (Join-Path $root 'DisplayMind.vcxproj') /nologo /verbosity:minimal /m:1 "/p:Configuration=$Configuration" /p:Platform=x64 "/p:Analyze=$($Analyze.IsPresent.ToString().ToLowerInvariant())"
	if ($LASTEXITCODE -ne 0) { throw "Native build failed ($LASTEXITCODE)." }
	if ($Tests) {
		& $msbuild (Join-Path $root 'DisplayMind.Tests.vcxproj') /nologo /verbosity:minimal /m:1 /p:Configuration=Release /p:Platform=x64
		if ($LASTEXITCODE -ne 0) { throw "Native test build failed ($LASTEXITCODE)." }
	}
} finally { $lock.Dispose() }
