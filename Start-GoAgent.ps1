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
$renderer=New-GoConsoleRenderer -HideReasoning:$HideReasoning
if ($ListModels) { Get-GoModelCatalog; return }
if (-not $env:OPENCODE_API_KEY) { throw '環境変数 OPENCODE_API_KEY に OpenCode Go の API キーを設定してください。' }
if ($Resume) {
    if (-not $SessionPath) { throw '-Resume requires -SessionPath.' }
    $thinkingOptions=@{}
    foreach ($key in @('ReasoningEffort','ThinkingBudget')) {if ($PSBoundParameters.ContainsKey($key)) {$thinkingOptions[$key]=$PSBoundParameters[$key]}}
    $agent=Import-GoSession -Path $SessionPath -Permission $Permission -BaseUri $BaseUri -MaxTurns $MaxTurns -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds -EnableImages:$EnableImages @thinkingOptions
} else {
    $agent=New-GoAgent -Model $Model -Protocol $Protocol -Workspace $Workspace -Permission $Permission -MaxTurns $MaxTurns -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds -EnableImages:$EnableImages -BaseUri $BaseUri -ReasoningEffort $ReasoningEffort -ThinkingBudget $ThinkingBudget
}
if ($PSBoundParameters.ContainsKey('Prompt')) { Invoke-GoAgent -Agent $agent -Prompt $Prompt -SessionPath $SessionPath -NoStream:$NoStream -OnEvent $renderer | Out-Null; return }
Write-Host "PSGoAgent | $($agent.Model) | $($agent.Protocol) | $($agent.Workspace)"
Write-Host '/exit 終了、/new 新規会話、/save PATH 保存、/upgrade 更新、/help ヘルプ'
while ($true) {
    $line=Read-Host 'you'
    if ($null -eq $line -or $line -eq '/exit') { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -eq '/help') {
        Write-Host '/exit, /new, /save PATH, /upgrade。複数行の依頼は -Prompt (Get-Content request.txt -Raw) で渡せます。'; continue
    }
    if ($line -eq '/upgrade') {
        try {
            if ($SessionPath) { Save-GoSession $agent $SessionPath }
            & (Join-Path $PSScriptRoot 'Upgrade.ps1')
            break
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        continue
    }
    if ($line -eq '/new') {
        $agent.History.Clear(); $agent.Id=[guid]::NewGuid().ToString()
        if ($SessionPath) { Save-GoSession $agent $SessionPath }
        Write-Host '新しい会話を開始しました。'; continue
    }
    if ($line.StartsWith('/save ')) { $SessionPath=$line.Substring(6).Trim(); Save-GoSession $agent $SessionPath; Write-Host "Saved: $SessionPath"; continue }
    try { Invoke-GoAgent -Agent $agent -Prompt $line -SessionPath $SessionPath -NoStream:$NoStream -OnEvent $renderer | Out-Null }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red }
}
