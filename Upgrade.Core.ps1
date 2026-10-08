function Invoke-GoReleaseUpgrade {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath,
        [scriptblock]$ReleaseRequest={param($Uri) Invoke-RestMethod -Uri $Uri -Headers @{'User-Agent'='power-agent'} -TimeoutSec 60},
        [scriptblock]$Download={param($Uri,$Path) Invoke-WebRequest -Uri $Uri -OutFile $Path -Headers @{'User-Agent'='power-agent'} -TimeoutSec 120})
    $ErrorActionPreference='Stop'
    $target=[IO.Path]::GetFullPath($TargetPath);$cursor=$target
    while ($cursor) {
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Upgrade destination must not contain symbolic links.'}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    if (Test-Path -LiteralPath $target -PathType Container) {throw 'Upgrade destination is a directory.'}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('power-agent-release-'+[guid]::NewGuid());$null=[IO.Directory]::CreateDirectory($temporary)
    $local=$null;$installed=$false;$existed=Test-Path -LiteralPath $target
    try {
        $release=& $ReleaseRequest 'https://api.github.com/repos/nakasyou/power-agent/releases/latest'
        if ($release.tag_name -notmatch '^v\d+\.\d+\.\d+$') {throw 'Unexpected release version.'}
        $assets=@{}
        foreach ($name in @('Power-Agent.ps1','SHA256SUMS.txt')) {
            $matches=@($release.assets | Where-Object name -EQ $name)
            if ($matches.Count -ne 1) {throw "Release asset missing: $name"}
            $uri=[uri]$matches[0].browser_download_url
            $prefix='/nakasyou/power-agent/releases/download/'+$release.tag_name+'/'
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -ne $prefix+$name) {throw 'Unexpected release asset URL.'}
            $assets[$name]=$uri.AbsoluteUri
        }
        $scriptPath=Join-Path $temporary 'Power-Agent.ps1';$checksums=Join-Path $temporary 'SHA256SUMS.txt'
        & $Download $assets['Power-Agent.ps1'] $scriptPath | Out-Null
        & $Download $assets['SHA256SUMS.txt'] $checksums | Out-Null
        if ((Get-Item $scriptPath).Length -gt 10MB) {throw 'Release script is too large.'}
        $hashLine=@(Get-Content $checksums | Where-Object {$_ -match '^[a-fA-F0-9]{64}\s+\*?Power-Agent\.ps1$'})
        if ($hashLine.Count -ne 1 -or ($hashLine[0] -split '\s+')[0] -ne (Get-FileHash $scriptPath -Algorithm SHA256).Hash) {throw 'Release checksum mismatch.'}
        $content=[IO.File]::ReadAllText($scriptPath)
        if ($content -notmatch '(?m)^\$script:PowerAgentVersion=''([0-9]+\.[0-9]+\.[0-9]+)''\r?$' -or 'v'+$Matches[1] -ne $release.tag_name) {throw 'Release script version mismatch.'}
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
        if ($errors.Count -or -not $content.Contains('$script:PowerAgentBundle=$true')) {throw 'Invalid bundled release script.'}
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $backup=Join-Path $temporary 'previous.ps1'
        if ($existed) {Copy-Item -LiteralPath $target -Destination $backup}
        $local=$target+'.'+[guid]::NewGuid()+'.tmp'
        Copy-Item -LiteralPath $scriptPath -Destination $local
        if (-not $IsWindows -and [Environment]::Version.Major -ge 7 -and $existed) {[IO.File]::SetUnixFileMode($local,[IO.File]::GetUnixFileMode($target))}
        [IO.File]::Move($local,$target,$true);$installed=$true
        if ($IsWindows) {Unblock-File -LiteralPath $target}
        Write-Host "Installed $($release.tag_name). Restart: $target" -ForegroundColor Green
        [pscustomobject]@{Version=$release.tag_name.Substring(1);Path=$target}
    } catch {
        if ($installed) {
            if ($existed) {Copy-Item -LiteralPath $backup -Destination $target -Force}
            else {Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue}
        }
        throw
    } finally {
        if ($local -and (Test-Path -LiteralPath $local)) {Remove-Item -LiteralPath $local -Force}
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
