#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Console.ps1')
$count=0
function Assert($Condition,$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$state=@{}
$render=New-GoConsoleRenderer -CompactReasoning -State $state
$output=& {
    & $render @{type='assistant_start'}
    & $render @{type='reasoning_delta';delta="hidden one`nhidden two`n"}
    & $render @{type='reasoning_delta';delta="last one`nlast two`nlast three"}
    & $render @{type='ui_tick'}
    & $render @{type='text_delta';delta='Assistant text'}
    & $render @{type='assistant_end'}
} 6>&1 | Out-String
Assert (-not $output.Contains('hidden one') -and -not $output.Contains('hidden two')) 'compact panel hides older reasoning lines'
Assert ($output.Contains('last one') -and $output.Contains('last three')) 'compact panel shows last three lines'
Assert ($state.reasoning.Contains('hidden one')) 'full reasoning retained for expansion'
Assert ($state.events.Count -eq 5) 'UI ticks never enter transcript'
Assert ($output.Contains('Assistant text')) 'reasoning panel keeps assistant text separate'
$state.expanded=$true
$output=Write-GoReasoningSummary $state 6>&1 | Out-String
Assert ($output.Contains('hidden one') -and $output.Contains('last three')) 'expanded panel displays complete reasoning'
$state.expanded=$false
$output=Write-GoReasoningSummary $state 6>&1 | Out-String
Assert (-not $output.Contains('hidden one')) 'panel can collapse again without deleting reasoning'
$hidden=New-GoConsoleRenderer -CompactReasoning -HideReasoning
$output=& {& $hidden @{type='reasoning_delta';delta='secret'};& $hidden @{type='text_delta';delta='visible'};& $hidden @{type='assistant_end'}} 6>&1 | Out-String
Assert (-not $output.Contains('secret') -and $output.Contains('visible')) 'HideReasoning suppresses compact panel'
$toolState=@{}
$toolRenderer=New-GoConsoleRenderer -CompactTools -Plain -State $toolState
$toolOutput=& {
    & $toolRenderer @{type='tool_start';name='powershell';callId='tool-1'}
    & $toolRenderer @{type='tool_output_delta';callId='tool-1';delta="hidden tool line`nline two`nline three`nline four"}
    & $toolRenderer @{type='tool_end';callId='tool-1';text='canonical result';isError=$false;details=@{exitCode=0}}
} 6>&1 | Out-String
Assert (-not $toolOutput.Contains('hidden tool line') -and $toolOutput.Contains('line four')) 'tool panel displays only the output tail'
$toolState.toolsExpanded=$true
$expanded=Write-GoToolSummary $toolState $toolState.toolPanels['tool-1'] 6>&1 | Out-String
Assert ($expanded.Contains('hidden tool line') -and $expanded.Contains('line four')) 'tool expansion retains full streamed output'
# A script invoked with & has a child scope, unlike pwsh -File. API module callbacks
# must retain its private renderer helpers across that module boundary.
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('console-scope-'+[guid]::NewGuid()+'.ps1')
$fixture=@'
$ErrorActionPreference='Stop'
Import-Module '__MODULE__' -Force
. '__CONSOLE__'
$state=@{}
$render=New-GoConsoleRenderer -CompactReasoning -State $state
$transport={param($Request) @{choices=@(@{finish_reason='stop';message=@{role='assistant';content='scope answer';reasoning_content="old one`nold two`nlast one`nlast two`nlast three"}})}}
$agent=New-GoAgent -Workspace '__WORKSPACE__' -Transport $transport
$answer=Invoke-GoAgent $agent 'scope request' -OnEvent $render
if ($answer -ne 'scope answer' -or $agent.History.Count -ne 2) {throw 'Turn failed across child script scope'}
foreach ($helper in @('tail','summary','live','toggle')) {if ($state[$helper] -isnot [scriptblock]) {throw "Missing bound helper: $helper"}}
'@
$fixture=$fixture.Replace('__MODULE__',(Join-Path $PSScriptRoot '../PSGoAgent.psd1').Replace("'","''")).Replace('__CONSOLE__',(Join-Path $PSScriptRoot '../Console.ps1').Replace("'","''")).Replace('__WORKSPACE__',$PSScriptRoot.Replace("'","''"))
try {
    Set-Content -LiteralPath $temporary -Value $fixture -Encoding utf8
    $command="& '"+$temporary.Replace("'","''")+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $output=& (Get-Process -Id $PID).Path -NoProfile -EncodedCommand $encoded 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $output.Contains('scope answer')) 'API callback resolves helpers from child script scope'
    Assert ($output.Contains('last three') -and -not $output.Contains('old one')) 'child-scope callback renders compact reasoning successfully'
} finally {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
Write-Host "All $count console assertions passed."
