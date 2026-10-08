#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('patch','minor','major')][string]$Bump,
    [string]$ManifestPath=(Join-Path $PSScriptRoot '../PSGoAgent.psd1'))
$ErrorActionPreference='Stop'
$current=[version](Import-PowerShellDataFile $ManifestPath).ModuleVersion
$next=switch ($Bump) {
    patch {'{0}.{1}.{2}' -f $current.Major,$current.Minor,($current.Build+1)}
    minor {'{0}.{1}.0' -f $current.Major,($current.Minor+1)}
    major {'{0}.0.0' -f ($current.Major+1)}
}
$content=[IO.File]::ReadAllText([IO.Path]::GetFullPath($ManifestPath))
$pattern=[regex]::new("ModuleVersion\s*=\s*'[^']*'")
if ($pattern.Matches($content).Count -ne 1) {throw 'Expected exactly one ModuleVersion.'}
$content=$pattern.Replace($content,"ModuleVersion = '$next'",1)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ManifestPath),$content,[Text.UTF8Encoding]::new($false))
$next
