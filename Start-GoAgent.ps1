#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$Model = 'glm-5.3-flash',
    [ValidateSet('Auto','Chat','Messages','Responses')][string]$Protocol = 'Auto',
    [string]$Workspace = (Get-Location).Path,
    [ValidateSet('Ask','ReadOnly','Auto')][string]$Permission = 'Ask',
    [string]$SessionPath,
    [switch]$Resume,
    [string]$SessionDirectory = (Join-Path $PSScriptRoot 'sessions'),
    [switch]$Plain,
    [ValidateRange(0,10)][int]$MaxRetries=2,
    [switch]$ListModels,
    [switch]$Upgrade,
    [switch]$EnableImages,
    [switch]$NoStream,
    [switch]$HideReasoning,
    [ValidateSet('Default','Low','Medium','High')][string]$ReasoningEffort='Default',
    [ValidateRange(0,65535)][int]$ThinkingBudget=0,
    [ValidateRange(1,1000)][int]$MaxTurns=30,
    [ValidateRange(1,65536)][int]$MaxTokens=8192,
    [ValidateRange(1,3600)][int]$TimeoutSeconds=120,
    [string]$BaseUri='https://opencode.ai/zen/go/v1'
)
$ErrorActionPreference='Stop'
if ($Upgrade) { & (Join-Path $PSScriptRoot 'Upgrade.ps1'); return }
Import-Module (Join-Path $PSScriptRoot 'PSGoAgent.psd1') -Force
. (Join-Path $PSScriptRoot 'Console.ps1')
$consoleState=@{}
$renderer=New-GoConsoleRenderer -HideReasoning:$HideReasoning -CompactReasoning -Plain:$Plain -State $consoleState
if ($ListModels) { Get-GoModelCatalog; return }
if (-not $env:OPENCODE_API_KEY) { throw 'Set OPENCODE_API_KEY to your OpenCode Go API key.' }
if ($Resume) {
    if (-not $SessionPath) {
        $latest=Get-GoSessionList $SessionDirectory ([IO.Path]::GetFullPath($Workspace)) | Sort-Object Updated -Descending | Select-Object -First 1
        if (-not $latest) {throw 'No saved sessions found.'}
        $SessionPath=$latest.Path
    }
    $thinkingOptions=@{}
    foreach ($key in @('ReasoningEffort','ThinkingBudget')) {if ($PSBoundParameters.ContainsKey($key)) {$thinkingOptions[$key]=$PSBoundParameters[$key]}}
    $agent=Import-GoSession -Path $SessionPath -Permission $Permission -BaseUri $BaseUri -MaxTurns $MaxTurns -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds -EnableImages:$EnableImages @thinkingOptions
} else {
    $agent=New-GoAgent -Model $Model -Protocol $Protocol -Workspace $Workspace -Permission $Permission -MaxTurns $MaxTurns -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds -EnableImages:$EnableImages -BaseUri $BaseUri -ReasoningEffort $ReasoningEffort -ThinkingBudget $ThinkingBudget
}
$agent | Add-Member -NotePropertyName MaxRetries -NotePropertyValue $MaxRetries -Force
if (-not $SessionPath) {$SessionPath=Join-Path $SessionDirectory ($agent.Id+'.session.json')}
Save-GoSession $agent $SessionPath
if ($PSBoundParameters.ContainsKey('Prompt')) { Invoke-GoAgent -Agent $agent -Prompt $Prompt -SessionPath $SessionPath -NoStream:$NoStream -OnEvent $renderer | Out-Null; return }
$inputHistory=[Collections.Generic.List[string]]::new()
foreach ($entry in $agent.History) {if ($entry.kind -eq 'user') {$inputHistory.Add($entry.text)}}
$failedPrompt=$null
if ($Resume) {Show-GoSessionTranscript $agent -Renderer $renderer -ConsoleState $consoleState}
while ($true) {
    Show-GoTerminalStatus $agent $SessionPath
    $line=Read-GoTerminalInput -History $inputHistory -Plain:$Plain -OnToggleReasoning {Switch-GoReasoningView $consoleState;Show-GoTerminalStatus $agent $SessionPath}
    if ($null -eq $line -or $line -eq '/exit') { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -eq '/help') {
        Write-Host '/exit quit · /new conversation · /save [PATH] · /resume [NUMBER|PATH] · /retry resend · /model [NAME] · /reasoning [Default|Low|Medium|High] · /thinking [BUDGET] · /upgrade update' -ForegroundColor Cyan; continue
    }
    if ($line -eq '/upgrade') {
        try {
            if ($SessionPath) { Save-GoSession $agent $SessionPath }
            & (Join-Path $PSScriptRoot 'Upgrade.ps1')
            break
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        continue
    }
    if ($line -eq '/model' -or $line.StartsWith('/model ')) {
        try {
            $choice=$line.Substring(6).Trim()
            if (-not $choice) {
                $models=@(Get-GoModelCatalog)
                $picked=Select-GoTerminalItem -Title 'Model' -Labels @($models | ForEach-Object {"$($_.Model) · $($_.Protocol)"}) -Plain:$Plain
                if ($picked -lt 0) {if ($Plain -or [Console]::IsInputRedirected) {$models | Format-Table -AutoSize};continue}
                $choice=$models[$picked].Model
            }
            $parts=$choice -split '\s+'
            if ($parts.Count -gt 2) {throw 'Usage: /model NAME [Chat|Messages|Responses]'}
            $options=@{}
            if ($parts.Count -eq 2) {$options.Protocol=$parts[1]}
            Set-GoModel $agent $parts[0] @options
            Save-GoSession $agent $SessionPath
            Write-Host "Model: $($agent.Model) / $($agent.Protocol)" -ForegroundColor Cyan
        } catch {Write-Host $_.Exception.Message -ForegroundColor Red}
        continue
    }
    if ($line -eq '/reasoning' -or $line.StartsWith('/reasoning ') -or $line -eq '/thinking' -or $line.StartsWith('/thinking ')) {
        try {
            $parts=$line -split '\s+',2
            if ($parts.Count -eq 1) {Write-Host "Reasoning: $($agent.ReasoningEffort) · Thinking budget: $($agent.ThinkingBudget)" -ForegroundColor Magenta;continue}
            if ($parts[0] -eq '/thinking') {Set-GoReasoning $agent -Budget ([int]$parts[1])}
            else {Set-GoReasoning $agent -Effort $parts[1].Trim()}
            Save-GoSession $agent $SessionPath
        } catch {Write-Host $_.Exception.Message -ForegroundColor Red}
        continue
    }
    if ($line -eq '/resume' -or $line.StartsWith('/resume ')) {
        try {
            $sessions=@(Get-GoSessionList $SessionDirectory $agent.Workspace | Sort-Object Updated -Descending)
            $selection=$line.Substring(7).Trim()
            if (-not $selection) {
                $picked=Select-GoTerminalItem -Title 'Resume session' -Labels @($sessions | ForEach-Object {"$($_.Updated.ToString('MM/dd HH:mm')) · $($_.Model) · $($_.Title)"}) -Plain:$Plain
                if ($picked -ge 0) {$selection=$sessions[$picked].Path}
                else {
                for ($i=0;$i -lt $sessions.Count;$i++) {Write-Host ("{0,3}  {1:MM/dd HH:mm}  {2}  {3}" -f ($i+1),$sessions[$i].Updated,$sessions[$i].Model,$sessions[$i].Title) -ForegroundColor Cyan}
                if (-not $sessions.Count) {Write-Host 'No saved sessions found.'}
                else {Write-Host 'Use /resume NUMBER or /resume PATH to resume.' -ForegroundColor DarkGray}
                continue
                }
            }
            $number=0
            if ([int]::TryParse($selection,[ref]$number)) {
                if ($number -lt 1 -or $number -gt $sessions.Count) {throw 'Session number is out of range.'}
                $selection=$sessions[$number-1].Path
            }
            $resumed=Import-GoSession -Path $selection -Permission $Permission -BaseUri $BaseUri -MaxTurns $MaxTurns -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds
            Save-GoSession $agent $SessionPath
            $agent=$resumed
            $agent | Add-Member -NotePropertyName MaxRetries -NotePropertyValue $MaxRetries -Force
            $SessionPath=[IO.Path]::GetFullPath($selection)
            $failedPrompt=$null
            $inputHistory.Clear()
            foreach ($entry in $agent.History) {if ($entry.kind -eq 'user') {$inputHistory.Add($entry.text)}}
            Show-GoSessionTranscript $agent -Renderer $renderer -ConsoleState $consoleState
        } catch {Write-Host $_.Exception.Message -ForegroundColor Red}
        continue
    }
    if ($line -eq '/new') {
        Save-GoSession $agent $SessionPath
        $agent.History.Clear(); $agent.Id=[guid]::NewGuid().ToString()
        $SessionPath=Join-Path $SessionDirectory ($agent.Id+'.session.json')
        if ($SessionPath) { Save-GoSession $agent $SessionPath }
        $failedPrompt=$null
        Show-GoSessionTranscript $agent -Renderer $renderer -ConsoleState $consoleState
        Write-Host 'Started a new conversation.'; continue
    }
    if ($line -eq '/save' -or $line.StartsWith('/save ')) {
        try {if ($line.StartsWith('/save ')) {$SessionPath=[IO.Path]::GetFullPath($line.Substring(6).Trim())};Save-GoSession $agent $SessionPath;Write-Host "Saved: $SessionPath" -ForegroundColor Green}
        catch {Write-Host $_.Exception.Message -ForegroundColor Red}
        continue
    }
    if ($line -eq '/retry') {
        $last=@($agent.History | Select-Object -Last 1)
        if ($last.Count -and $last[0].kind -eq 'result') {$line='Continue using the previous tool results. Do not execute completed tools again.'}
        elseif ($failedPrompt) {$line=$failedPrompt}
        else {Write-Host 'No failed request to resend.' -ForegroundColor Yellow;continue}
    } elseif ($line.StartsWith('/')) {Write-Host 'Unknown command. See /help.' -ForegroundColor Yellow;continue}
    $null=& $renderer @{type='user';text=$line;silent=$consoleState.native}
    $cancellation=[Threading.CancellationTokenSource]::new()
    $consoleState.cancellation=$cancellation
    $oldControl=[Console]::TreatControlCAsInput
    if ($consoleState.native) {[Console]::TreatControlCAsInput=$true}
    try { Invoke-GoAgent -Agent $agent -Prompt $line -SessionPath $SessionPath -NoStream:$NoStream -OnEvent $renderer -CancellationToken $cancellation.Token | Out-Null; $failedPrompt=$null }
    catch { $failedPrompt=$line; Write-Host $_.Exception.Message -ForegroundColor Red }
    finally {
        [Console]::TreatControlCAsInput=$oldControl
        $consoleState.cancellation=$null;$cancellation.Dispose()
    }
}
Save-GoSession $agent $SessionPath
