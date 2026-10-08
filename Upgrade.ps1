#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Upgrade.Core.ps1')
Invoke-GoReleaseUpgrade -TargetPath (Join-Path $PSScriptRoot 'Power-Agent.ps1')
