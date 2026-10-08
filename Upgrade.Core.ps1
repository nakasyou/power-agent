# Download and stage before touching the installation. Only distributed paths are replaced.
function Invoke-GoUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [string]$ArchiveUri='https://github.com/nakasyou/power-agent/archive/refs/heads/main.zip',
        [scriptblock]$Download={param($Uri,$Path) Invoke-WebRequest -Uri $Uri -OutFile $Path -TimeoutSec 120}
    )
    $ErrorActionPreference='Stop'
    $install=[IO.Path]::GetFullPath($InstallDirectory)
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('power-agent-upgrade-'+[guid]::NewGuid())
    $null=New-Item -ItemType Directory -Path $temporary
    $changed=[Collections.Generic.List[object]]::new()
    try {
        $archive=Join-Path $temporary 'latest.zip'
        & $Download $ArchiveUri $archive | Out-Null
        $stage=Join-Path $temporary 'stage'
        $null=New-Item -ItemType Directory -Path $stage
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                $name=$entry.FullName.Replace('\','/')
                if ($name.StartsWith('/') -or $name.Contains(':') -or @($name.Split('/') | Where-Object {$_ -eq '..'}).Count) {throw "Unsafe archive entry: $name"}
                if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {throw "Archive symlink is not supported: $name"}
            }
        } finally {$zip.Dispose()}
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        $roots=@(Get-ChildItem -LiteralPath $stage -Directory)
        if ($roots.Count -ne 1 -or @(Get-ChildItem -LiteralPath $stage -File).Count) {throw 'Unexpected GitHub archive layout.'}
        $source=$roots[0].FullName
        # A fixed allowlist keeps sessions, secrets, .git and user files intact.
        $paths=@('PSGoAgent.psd1','PSGoAgent.psm1','Tools.ps1','Streaming.ps1','Console.ps1','Start-GoAgent.ps1','Upgrade.ps1','Upgrade.Core.ps1','README.md','LICENSE','docs','tests')
        foreach ($required in $paths) {
            if (-not (Test-Path -LiteralPath (Join-Path $source $required))) {throw "Incomplete update: $required is missing."}
        }
        $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $source 'PSGoAgent.psd1')
        if ($manifest.RootModule -ne 'PSGoAgent.psm1' -or -not $manifest.ModuleVersion) {throw 'Invalid update manifest.'}
        $files=@(foreach ($path in $paths) {Get-ChildItem -LiteralPath (Join-Path $source $path) -File -Recurse})
        foreach ($file in $files) {
            $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
            $destination=Join-Path $install $relative
            $cursor=$destination
            while ($cursor) {
                $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw "Update destination contains a link: $cursor"}
                if ($cursor -eq $install) {break}
                $cursor=[IO.Path]::GetDirectoryName($cursor)
            }
            if (Test-Path -LiteralPath $destination -PathType Container) {throw "Update destination is a directory: $destination"}
        }
        foreach ($file in $files) {
            $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
            $destination=Join-Path $install $relative
            $backup=Join-Path (Join-Path $temporary 'backup') $relative
            $existed=Test-Path -LiteralPath $destination
            if ($existed) {
                $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backup)) -Force
                Copy-Item -LiteralPath $destination -Destination $backup
            }
            $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force
            $changed.Add(@{Destination=$destination;Backup=$backup;Existed=$existed})
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            if ($IsWindows) {Unblock-File -LiteralPath $destination}
        }
        [pscustomobject]@{Version=$manifest.ModuleVersion;Directory=$install}
    } catch {
        $failure=$_
        for ($i=$changed.Count-1;$i -ge 0;$i--) {
            $change=$changed[$i]
            try {
                if ($change.Existed) {Copy-Item -LiteralPath $change.Backup -Destination $change.Destination -Force}
                else {Remove-Item -LiteralPath $change.Destination -Force -ErrorAction SilentlyContinue}
            } catch {Write-Warning "Could not restore $($change.Destination): $_"}
        }
        throw $failure
    } finally {Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}
}
