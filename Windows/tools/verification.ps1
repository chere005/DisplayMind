function Get-DisplayMindSourceHash([string]$Root) {
	$paths = @('src','tests','tools','Resources','DisplayMind.vcxproj','DisplayMind.Tests.vcxproj','app.rc','app.manifest','README.md','SOURCE.json','AGENTS.md','.gitignore')
	$lines = foreach ($path in $paths) {
		$entry = Get-Item -LiteralPath (Join-Path $Root $path)
		$files = if ($entry.PSIsContainer) { Get-ChildItem -LiteralPath $entry.FullName -Recurse -File } else { @($entry) }
		foreach ($file in $files) {
			$relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\','/')
			$relative + ':' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
		}
	}
	$bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines | Sort-Object) -join "`n")
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { return [Convert]::ToHexString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}
