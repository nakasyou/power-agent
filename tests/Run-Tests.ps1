#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$script:passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('psgo-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $root
$module=Get-Module PSGoAgent
try {
    foreach ($protocol in @('Chat','Messages','Responses')) {
        $state=@{step=0;requests=[Collections.Generic.List[object]]::new()}
        $transport={
            param($request)
            $state.requests.Add($request)
            $state.step++
            if ($state.step -eq 1) {
                switch ($protocol) {
                    'Chat' { @{choices=@(@{finish_reason='tool_calls';message=@{role='assistant';content=$null;reasoning_content='preserve me';tool_calls=@(@{id='call-1';type='function';function=@{name='write';arguments='{"path":"hello.txt","content":"こんにちは"}'}})}})} }
                    'Messages' { @{stop_reason='tool_use';content=@(@{type='thinking';thinking='preserve me';signature='sig'},@{type='tool_use';id='call-1';name='write';input=@{path='hello.txt';content='こんにちは'}})} }
                    'Responses' { @{status='completed';output=@(@{type='reasoning';id='r1';summary=@()},@{type='function_call';id='f1';call_id='call-1';name='write';arguments='{"path":"hello.txt","content":"こんにちは"}'})} }
                }
            } else {
                switch ($protocol) {
                    'Chat' { @{choices=@(@{finish_reason='stop';message=@{role='assistant';content='完了'}})} }
                    'Messages' { @{stop_reason='end_turn';content=@(@{type='text';text='完了'})} }
                    'Responses' { @{status='completed';output=@(@{type='message';id='m1';role='assistant';content=@(@{type='output_text';text='完了'})})} }
                }
            }
        }.GetNewClosure()
        $agent=New-GoAgent -Model test -Protocol $protocol -Workspace $root -Permission Auto -Transport $transport
        $session=Join-Path $root "$protocol.json"
        $answer=Invoke-GoAgent $agent 'ファイルを作って' -SessionPath $session
        Assert ($answer -eq '完了') "$protocol tool loop returns final answer"
        Assert ([IO.File]::ReadAllText((Join-Path $root 'hello.txt')) -eq 'こんにちは') "$protocol tool writes UTF-8"
        Assert ($state.requests.Count -eq 2) "$protocol performs two requests"
        Assert ($state.requests[0].Headers['x-opencode-session'] -eq $state.requests[1].Headers['x-opencode-session']) "$protocol stable session header"
        $second=$state.requests[1].Body | ConvertTo-Json -Depth 100 -Compress
        Assert ($second.Contains('call-1') -and $second.Contains('Wrote')) "$protocol sends correlated tool result"
        Assert ($second.Contains('preserve me') -or $second.Contains('reasoning')) "$protocol preserves reasoning blocks"
        $loaded=Import-GoSession $session -Transport $transport
        Assert ($loaded.Id -eq $agent.Id -and $loaded.History.Count -eq 4) "$protocol session round trip"
        Assert ($loaded.Permission -eq 'Ask') "$protocol resume defaults to approval"
        Assert (-not ([IO.File]::ReadAllText($session).Contains('Authorization'))) "$protocol session excludes credentials"
    }
    $a=New-GoAgent -Workspace $root -Permission Auto
    Assert ($a.Protocol -eq 'Chat') 'automatic model routing'
    Assert ((New-GoAgent -Workspace $root -Model minimax-m2.7).Protocol -eq 'Messages') 'Messages model routing'
    Assert ((New-GoAgent -Workspace $root -Model gpt-6-luna).Protocol -eq 'Responses') 'Responses model routing'
    $tool={param($a,$name,$toolArguments) & $module {param($a,$name,$arguments) Invoke-GoTool $a $name $arguments} $a $name $toolArguments}.GetNewClosure()
    $r=& $tool $a write @{path='../escape.txt';content='bad'}
    Assert $r.isError 'rejects traversal'
    $r=& $tool $a write @{path='hello.txt';content='one one'}
    $r=& $tool $a edit @{path='hello.txt';oldText='one';newText='two'}
    Assert ($r.isError -and [IO.File]::ReadAllText((Join-Path $root 'hello.txt')) -eq 'one one') 'ambiguous edit leaves file unchanged'
    $r=& $tool $a edit @{path='hello.txt';oldText='one one';newText="two`r`nthree"}
    Assert (-not $r.isError) 'unique edit succeeds'
    $r=& $tool $a read @{path='hello.txt';offset=2;limit=1}
    Assert ($r.text.Contains('2: three')) 'read supports line offsets'
    $r=& $tool $a read @{path='hello.txt';limit=0}
    Assert $r.isError 'rejects invalid read limits'
    $r=& $tool $a missing @{}
    Assert $r.isError 'unknown tool is an error result'
    $r=& $tool $a write @{path='hello.txt'}
    Assert $r.isError 'validates required arguments'
    $a.Permission='ReadOnly'
    $r=& $tool $a shell @{command="'bad'"}
    Assert $r.isError 'read-only denies shell'
    $a.Permission='Ask';$a.Approve={param($name,$arguments) $false}
    $r=& $tool $a write @{path='denied.txt';content='bad'}
    Assert ($r.isError -and -not (Test-Path (Join-Path $root 'denied.txt'))) 'approval denial prevents mutation'
    $a.Permission='Auto'
    $r=& $tool $a shell @{command="[Console]::WriteLine('shell-ok'); [Console]::Error.WriteLine('stderr-ok')"}
    Assert (-not $r.isError -and $r.text.Contains('exit_code: 0') -and $r.text.Contains('shell-ok') -and $r.text.Contains('stderr-ok')) 'shell captures both streams'
    $r=& $tool $a shell @{command="throw 'expected failure'"}
    Assert ($r.text.Contains('exit_code: 1')) 'shell reports PowerShell failures'
    $r=& $tool $a shell @{command='Start-Sleep 10';timeoutSeconds=1}
    Assert ($r.isError -and $r.text.Contains('timed out')) 'shell timeout stops process'
    $r=& $tool $a shell @{command='Get-Location'}
    Assert ($r.text.Contains($root)) 'shell working directory is workspace'
    if (-not $IsWindows) {
        $link=Join-Path $root 'outside'
        $null=New-Item -ItemType SymbolicLink -Path $link -Target ([IO.Path]::GetTempPath())
        $r=& $tool $a write @{path='outside/escape.txt';content='bad'}
        Assert $r.isError 'rejects symlink traversal'
    }
    # Multiple calls and malformed JSON must each receive an error/result and continue.
    $state=@{step=0;body=$null}
    $multi={param($request)
        $state.step++
        if ($state.step -eq 1) {
            @{choices=@(@{finish_reason='tool_calls';message=@{role='assistant';content=$null;tool_calls=@(
                @{id='a';type='function';function=@{name='read';arguments='{broken'}},
                @{id='b';type='function';function=@{name='list';arguments='{"path":"."}'}}
            )}})}
        } else { $state.body=$request.Body; @{choices=@(@{finish_reason='stop';message=@{role='assistant';content='ok'}})} }
    }.GetNewClosure()
    $a=New-GoAgent -Workspace $root -Transport $multi
    $null=Invoke-GoAgent $a 'test'
    Assert (@($state.body.messages | Where-Object role -EQ tool).Count -eq 2) 'multiple tool calls including malformed JSON all get results'
    $fail={param($request) throw 'network failed'}
    $a=New-GoAgent -Workspace $root -Transport $fail
    try { Invoke-GoAgent $a 'test' } catch {}
    Assert ($a.History.Count -eq 0 -and -not $a.Busy) 'network failure rolls back incomplete exchange'
    $truncated={param($request) @{choices=@(@{finish_reason='length';message=@{role='assistant';content='partial'}})}}
    $a=New-GoAgent -Workspace $root -Transport $truncated
    try { Invoke-GoAgent $a 'test' } catch {}
    Assert ($a.History.Count -eq 0) 'truncated answer is rejected'
    $loop={param($request) @{choices=@(@{finish_reason='tool_calls';message=@{role='assistant';content=$null;tool_calls=@(@{id='c';type='function';function=@{name='list';arguments='{"path":"."}'}})}})}}
    $a=New-GoAgent -Workspace $root -Transport $loop -MaxTurns 1
    try { Invoke-GoAgent $a 'test' } catch { Assert ($_.Exception.Message.Contains('Maximum turns')) 'turn limit terminates loop' }
    Assert ($a.History.Count -eq 3) 'turn limit retains complete tool exchange'
    Write-Host "All $script:passed assertions passed."
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
