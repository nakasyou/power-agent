#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
. (Join-Path $PSScriptRoot '../Console.ps1')
$count=0
function Assert($Condition,$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('terminal-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory $root
$module=Get-Module PSGoAgent
try {
    $a=New-GoAgent -Workspace $root -Permission ReadOnly
    $a.History.Add(@{kind='user';text='Inspect the café project'})
    $a.History.Add(@{kind='assistant';text='Investigating';calls=@(@{id='c1';name='read';arguments='{"path":"README.md"}'});raw=@{role='assistant';content='Investigating';reasoning_content='private reasoning'}})
    $a.History.Add(@{kind='result';callId='c1';text='result';isError=$false;content=@();details=@{}})
    $id=$a.Id
    foreach ($model in @('gpt-6-luna','minimax-m2.7','glm-5.3-flash')) {
        Set-GoModel $a $model
        Assert ($a.Id -eq $id -and $a.History.Count -eq 3) "$model switch preserves conversation and tool results"
        $request=& $module {param($Agent) New-GoRequest $Agent} $a
        $json=$request.Body | ConvertTo-Json -Depth 100
        Assert ($json.Contains('Inspect the café project') -and $json.Contains('c1') -and $json.Contains('result')) "$model request contains converted history"
        Assert (-not $json.Contains('private reasoning')) "$model does not replay foreign reasoning"
        switch ($a.Protocol) {
            'Responses' {Assert ($request.Body.input[1].type -eq 'message' -and $request.Body.input[2].type -eq 'function_call') 'Responses history uses output blocks'}
            'Messages' {Assert ($request.Body.messages[1].content[1].type -eq 'tool_use') 'Messages history uses tool_use'}
            'Chat' {Assert ($request.Body.messages[2].tool_calls[0].function.name -eq 'read') 'Chat history uses tool_calls'}
        }
    }
    Set-GoReasoning $a -Effort High
    $request=& $module {param($Agent) New-GoRequest $Agent} $a
    Assert ($request.Body.reasoning_effort -eq 'high') 'reasoning effort changes next request'
    $sessionDir=Join-Path $root 'sessions'
    $path=Join-Path $sessionDir ($a.Id+'.session.json')
    Save-GoSession $a $path
    $resumed=Import-GoSession $path
    Assert ($resumed.ReasoningEffort -eq 'High' -and $resumed.Id -eq $id -and $resumed.History.Count -eq 3) 'resume restores settings and history'
    Assert ($resumed.Permission -eq 'Ask') 'resume does not grant saved permissions'
    Set-GoModel $a minimax-m2.7
    Assert ($a.ReasoningEffort -eq 'Default') 'model switch resets model-specific settings'
    Set-GoReasoning $a -Budget 2048
    Save-GoSession $a $path
    Assert ((Import-GoSession $path).ThinkingBudget -eq 2048) 'thinking budget survives resume'
    $failed=$false
    try {Set-GoReasoning $a -Budget 9000} catch {$failed=$true}
    Assert ($failed -and $a.ThinkingBudget -eq 2048) 'invalid reasoning settings leave current value intact'
    $failed=$false
    try {Set-GoReasoning $a -Effort High} catch {$failed=$true}
    Assert $failed 'Messages requires thinking budget'
    $failed=$false
    try {Set-GoModel $a unknown} catch {$failed=$true}
    Assert ($failed -and $a.Model -eq 'minimax-m2.7') 'unknown model leaves current model intact'
    Set-Content (Join-Path $sessionDir 'broken.session.json') '{broken'
    $other=New-GoAgent -Workspace $PSScriptRoot
    Save-GoSession $other (Join-Path $sessionDir 'other.session.json')
    $list=@(Get-GoSessionList $sessionDir $root)
    Assert ($list.Count -eq 1 -and $list[0].Title -eq 'Inspect the café project') 'session list filters workspace and invalid files'
    Assert (-not ((Get-Content $path -Raw).Contains('Authorization'))) 'session contains no credentials'
    # Exercise actual CLI command routing with redirected input and no API requests.
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Environment['OPENCODE_API_KEY']='mock-terminal-key'
    foreach ($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot '../Start-GoAgent.ps1'),'-Plain','-Workspace',$root,'-SessionDirectory',$sessionDir,'-Resume','-SessionPath',$path)) {$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        $null=$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        foreach ($line in @('/model gpt-6-luna','/reasoning High','/save','/new',"/resume $path",'/resume','/model unknown','/reasoning Invalid','/exit')) {$process.StandardInput.WriteLine($line)}
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {$process.Kill($true);throw 'CLI timeout'}
        $text=$output.GetAwaiter().GetResult();$errorText=$errors.GetAwaiter().GetResult()
        Assert ($process.ExitCode -eq 0 -and -not $errorText) 'CLI session commands complete without process errors'
        $saved=Import-GoSession $path
        Assert ($saved.Model -eq 'gpt-6-luna' -and $saved.ReasoningEffort -eq 'High') 'CLI persists model and effort changes'
        Assert ($saved.History.Count -eq 3) 'CLI /new preserves original and /resume restores it'
        Assert (@(Get-ChildItem $sessionDir -Filter '*.session.json').Count -eq 4) 'CLI /new saves to a separate session file'
        Assert ($text.Contains('Inspect the café project') -and $text.Contains('reasoning High')) 'CLI redraws resumed transcript and settings'
    } finally {$process.Dispose()}
    Write-Host "All $count terminal assertions passed."
} finally {Remove-Item $root -Recurse -Force}
