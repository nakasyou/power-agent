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
    & $render @{type='text_delta';delta='本文'}
    & $render @{type='assistant_end'}
} 6>&1 | Out-String
Assert (-not $output.Contains('hidden one') -and -not $output.Contains('hidden two')) 'compact panel hides older reasoning lines'
Assert ($output.Contains('last one') -and $output.Contains('last three')) 'compact panel shows last three lines'
Assert ($state.reasoning.Contains('hidden one')) 'full reasoning retained for expansion'
Assert ($state.events.Count -eq 5) 'UI ticks never enter transcript'
Assert ($output.Contains('本文')) 'reasoning panel keeps assistant text separate'
$state.expanded=$true
$output=Write-GoReasoningSummary $state 6>&1 | Out-String
Assert ($output.Contains('hidden one') -and $output.Contains('last three')) 'expanded panel displays complete reasoning'
$state.expanded=$false
$output=Write-GoReasoningSummary $state 6>&1 | Out-String
Assert (-not $output.Contains('hidden one')) 'panel can collapse again without deleting reasoning'
$hidden=New-GoConsoleRenderer -CompactReasoning -HideReasoning
$output=& {& $hidden @{type='reasoning_delta';delta='secret'};& $hidden @{type='text_delta';delta='visible'};& $hidden @{type='assistant_end'}} 6>&1 | Out-String
Assert (-not $output.Contains('secret') -and $output.Contains('visible')) 'HideReasoning suppresses compact panel'
Write-Host "All $count console assertions passed."
