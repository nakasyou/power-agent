using module PSScriptBuilder
#requires -Version 7.2
[CmdletBinding()]
param([string]$OutputPath=(Join-Path $PSScriptRoot '../dist/Power-Agent.ps1'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest=Import-PowerShellDataFile (Join-Path $root 'PSGoAgent.psd1')
$entryPath=Join-Path $root 'Start-GoAgent.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entryPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw 'Invalid CLI source.'}
$source=[IO.File]::ReadAllText($entryPath)
$header=$source.Substring(0,$ast.ParamBlock.Extent.EndOffset)
$entry=$source.Substring($ast.ParamBlock.Extent.EndOffset)
$template=$header+"`n`n"+'$script:PowerAgentBundle=$true'+"`n"+'$script:PowerAgentSelfPath=$PSCommandPath'+"`n"+('$script:PowerAgentVersion='''+$manifest.ModuleVersion+'''')+"`n{{FUNCTION_DEFINITIONS}}`n"+$entry
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('power-agent-build-'+[guid]::NewGuid()+'.template')
try {
    [IO.File]::WriteAllText($temporary,$template,[Text.UTF8Encoding]::new($false))
    Set-PSScriptBuilderProjectRoot -Path $root
    $collector=New-PSScriptBuilderContentCollector | Add-PSScriptBuilderCollector -Type Function -IncludeFile @('PSGoAgent.psm1','Tools.ps1','Streaming.ps1','Console.ps1','Upgrade.Core.ps1') -FileExtension @('.ps1','.psm1')
    $null=Invoke-PSScriptBuilderBuild -ContentCollector $collector -TemplatePath $temporary -OutputPath ([IO.Path]::GetFullPath($OutputPath))
    $outputErrors=$null;$outputTokens=$null
    $null=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($OutputPath),[ref]$outputTokens,[ref]$outputErrors)
    if ($outputErrors.Count) {throw 'Bundled script failed syntax validation.'}
    Write-Host "Built $OutputPath ($($manifest.ModuleVersion))"
} finally {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
