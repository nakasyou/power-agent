#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Upgrade.Core.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('upgrade-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $root
$count=0
function Assert($Condition,$Message) {if (-not $Condition) {throw $Message};$script:count++;Write-Host "PASS: $Message"}
try {
    $package=Join-Path $root 'package/power-agent-main'
    $null=New-Item -ItemType Directory -Path $package -Force
    foreach ($path in @('PSGoAgent.psd1','PSGoAgent.psm1','Tools.ps1','Streaming.ps1','Console.ps1','Start-GoAgent.ps1','Upgrade.ps1','Upgrade.Core.ps1','README.md','LICENSE','docs','tests')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../$path") -Destination $package -Recurse
    }
    $zip=Join-Path $root 'latest.zip'
    Compress-Archive -Path $package -DestinationPath $zip
    $install=Join-Path $root 'install'
    $null=New-Item -ItemType Directory -Path (Join-Path $install 'sessions') -Force
    Set-Content (Join-Path $install 'sessions/test.session.json') 'session'
    Set-Content (Join-Path $install '.env') 'secret'
    Set-Content (Join-Path $install 'custom.txt') 'custom'
    Set-Content (Join-Path $install 'README.md') 'old'
    $download={param($Uri,$Path) Copy-Item -LiteralPath $zip -Destination $Path}.GetNewClosure()
    $result=Invoke-GoUpgrade -InstallDirectory $install -Download $download
    Assert ($result.Version -eq '0.4.0') 'version comes from downloaded manifest'
    Assert (Test-Path (Join-Path $install 'Start-GoAgent.ps1')) 'archive root is flattened'
    Assert (-not (Test-Path (Join-Path $install 'power-agent-main'))) 'no nested installation'
    Assert ((Get-Content (Join-Path $install '.env')) -eq 'secret') 'secrets preserved'
    Assert ((Get-Content (Join-Path $install 'sessions/test.session.json')) -eq 'session') 'sessions preserved'
    Assert ((Get-Content (Join-Path $install 'custom.txt')) -eq 'custom') 'custom files preserved'
    $before=Get-Content (Join-Path $install 'README.md') -Raw
    $failed=$false
    try {Invoke-GoUpgrade -InstallDirectory $install -Download {throw 'network failure'}} catch {$failed=$true}
    Assert $failed 'download failure reported'
    Assert ((Get-Content (Join-Path $install 'README.md') -Raw) -eq $before) 'download failure leaves installation intact'
    $bad=Join-Path $root 'bad.zip'
    $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create)
    $null=$archive.CreateEntry('power-agent-main/../../escape.txt');$archive.Dispose()
    $badDownload={param($Uri,$Path) Copy-Item $bad $Path}.GetNewClosure()
    $failed=$false
    try {Invoke-GoUpgrade -InstallDirectory $install -Download $badDownload} catch {$failed=$true}
    Assert $failed 'zip path traversal rejected'
    Assert (-not (Test-Path (Join-Path $root 'escape.txt'))) 'zip cannot escape staging directory'
    Remove-Item (Join-Path $package 'Tools.ps1')
    Remove-Item $zip
    Compress-Archive -Path $package -DestinationPath $zip
    $failed=$false
    try {Invoke-GoUpgrade -InstallDirectory $install -Download $download} catch {$failed=$true}
    Assert $failed 'incomplete package rejected'
    Assert ((Get-Content (Join-Path $install 'README.md') -Raw) -eq $before) 'incomplete package leaves installation intact'
    Write-Host "$count upgrade assertions passed."
} finally {Remove-Item $root -Recurse -Force}
