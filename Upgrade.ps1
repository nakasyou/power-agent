#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Upgrade.Core.ps1')
$result=Invoke-GoUpgrade -InstallDirectory $PSScriptRoot
Write-Host "Updated PSGoAgent to $($result.Version) in $($result.Directory). Restart the agent to use the update."
