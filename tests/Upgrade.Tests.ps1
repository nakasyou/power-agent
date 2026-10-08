#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Upgrade.Core.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('release-upgrade-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
$count=0
function Assert($Condition,$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
try {
    $source=Join-Path $root 'download.ps1';$sum=Join-Path $root 'checksums.txt';$target=Join-Path $root 'install/Power-Agent.ps1'
    Set-Content $source "#requires -Version 7.2`n`$script:PowerAgentVersion='0.6.0'`n`$script:PowerAgentBundle=`$true`nWrite-Output 'new bundle'"
    Set-Content $sum ((Get-FileHash $source -Algorithm SHA256).Hash+'  Power-Agent.ps1')
    $release=@{tag_name='v0.6.0';assets=@(@{name='Power-Agent.ps1';browser_download_url='https://github.com/nakasyou/power-agent/releases/download/v0.6.0/Power-Agent.ps1'},@{name='SHA256SUMS.txt';browser_download_url='https://github.com/nakasyou/power-agent/releases/download/v0.6.0/SHA256SUMS.txt'})}
    $request={param($Uri) $release}.GetNewClosure()
    $download={param($Uri,$Path) Copy-Item $(if ($Uri.EndsWith('.ps1')) {$source} else {$sum}) $Path}.GetNewClosure()
    $null=New-Item -ItemType Directory (Join-Path $root 'install/sessions') -Force
    Set-Content $target 'old bundle';Set-Content (Join-Path $root 'install/.env') 'secret';Set-Content (Join-Path $root 'install/sessions/example.session.json') 'history'
    $result=Invoke-GoReleaseUpgrade -TargetPath $target -ReleaseRequest $request -Download $download
    Assert ($result.Version -eq '0.6.0' -and (Get-Content $target -Raw).Contains('new bundle')) 'release asset replaces target script'
    Assert ((Get-Content (Join-Path $root 'install/.env')) -eq 'secret') 'secrets preserved'
    Assert ((Get-Content (Join-Path $root 'install/sessions/example.session.json')) -eq 'history') 'sessions preserved'
    $before=Get-Content $target -Raw
    Set-Content $sum ('0'*64+'  Power-Agent.ps1')
    $failed=$false;try {Invoke-GoReleaseUpgrade -TargetPath $target -ReleaseRequest $request -Download $download} catch {$failed=$true}
    Assert ($failed -and (Get-Content $target -Raw) -eq $before) 'checksum mismatch leaves installation intact'
    $failed=$false;try {Invoke-GoReleaseUpgrade -TargetPath $target -ReleaseRequest {throw 'network failure'}} catch {$failed=$true}
    Assert ($failed -and (Get-Content $target -Raw) -eq $before) 'download failure leaves installation intact'
    $release.assets[0].browser_download_url='https://example.com/malicious.ps1'
    $failed=$false;try {Invoke-GoReleaseUpgrade -TargetPath $target -ReleaseRequest $request -Download $download} catch {$failed=$true}
    Assert $failed 'untrusted asset URL rejected'
    $manifest=Join-Path $root 'version.psd1'
    foreach ($bump in @('patch','minor','major')) {
        Set-Content $manifest "@{ModuleVersion='1.2.3'}"
        $version=& (Join-Path $PSScriptRoot '../scripts/Bump-Version.ps1') -ManifestPath $manifest -Bump $bump
        $expected=switch ($bump) {patch {'1.2.4'} minor {'1.3.0'} major {'2.0.0'}}
        Assert ($version -eq $expected -and (Import-PowerShellDataFile $manifest).ModuleVersion -eq $expected) "$bump increments version correctly"
    }
    Write-Host "All $count release upgrade assertions passed."
} finally {Remove-Item $root -Recurse -Force}
