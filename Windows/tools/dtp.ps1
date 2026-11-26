param(
	[string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\DisplayMind'),
	[switch]$Verified,
	[switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
. (Join-Path $PSScriptRoot 'verification.ps1')
function Git-Checked {
	& git -C $repo @args
	if ($LASTEXITCODE -ne 0) { throw "Git failed: $($args -join ' ')" }
}
$branch = (Git-Checked branch --show-current).Trim()
if ($branch -ne 'main') { throw "Release requires main, found $branch." }
$origin = (Git-Checked remote get-url origin).Trim()
if ($origin -notmatch '^(git@|ssh://)') { throw 'DisplayMind releases require an SSH origin.' }
$version = (Get-Content -LiteralPath (Join-Path $root 'SOURCE.json') -Raw | ConvertFrom-Json).windowsVersion
if ($version -notmatch '^\d+\.\d+\.0$') { throw 'Windows version must be X.Y.0.' }
$tag = "windows-v$version"
$changes = @(Git-Checked status --porcelain --untracked-files=all)
foreach ($change in $changes) {
	if ($change -and $change.Substring(3) -notmatch '^(Windows/|README\.md$)') { throw "Unrelated change is preserved; release stopped: $change" }
}
if ($DryRun) {
	@("Verify Windows $version", 'Run preflight and isolated installer checks', 'Package the verified executable and matching source',
		'Fetch SSH origin and require current main', 'Commit Windows/ and README.md', "Create $tag and push main + tag atomically", "Install to $InstallDirectory preserving settings and recovery")
	return
}
if (-not $Verified) { & (Join-Path $PSScriptRoot 'preflight.ps1') }
$report = Get-Content -LiteralPath (Join-Path $root 'artifacts\verification.json') -Raw | ConvertFrom-Json
if ($report.version -ne $version -or $report.sourceSha256 -ne (Get-DisplayMindSourceHash $root)) { throw 'Current sources/version have not passed preflight.' }
& (Join-Path $PSScriptRoot 'test-install.ps1') | Set-Content -LiteralPath (Join-Path $root 'artifacts\install-tests.json') -Encoding utf8NoBOM
& (Join-Path $PSScriptRoot 'package.ps1')
Git-Checked fetch --tags origin
& git -C $repo merge-base --is-ancestor origin/main HEAD
if ($LASTEXITCODE -ne 0) { throw 'Remote main has newer work. Integrate it and rerun preflight before release.' }
Git-Checked add -- Windows README.md
& git -C $repo diff --cached --quiet
if ($LASTEXITCODE -eq 1) { Git-Checked commit -m "DisplayMind Windows ${version}: Mac parity and verified installation" }
elseif ($LASTEXITCODE -ne 0) { throw 'Could not inspect staged changes.' }
$existing = & git -C $repo rev-parse --verify --quiet "refs/tags/$tag^{commit}"
if ($LASTEXITCODE -eq 0) {
	if ($existing -ne (Git-Checked rev-parse HEAD)) { throw "$tag already names a different commit." }
} else { Git-Checked tag -a $tag -m "DisplayMind Windows $version" }
Git-Checked push --atomic origin main $tag
& (Join-Path $PSScriptRoot 'install.ps1') -InstallDirectory $InstallDirectory -Launch
Write-Output "Released $tag and installed Windows $version."
