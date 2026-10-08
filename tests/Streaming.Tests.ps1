#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$module=Get-Module PSGoAgent
$script:passed=0
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('psgo-stream-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($root)
$oldKey=$env:OPENCODE_API_KEY;$env:OPENCODE_API_KEY='mock-stream-key'
function Start-Server([string]$Protocol,[string]$Scenario='Normal') {
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
    $ready=Join-Path $root ([guid]::NewGuid().ToString()+'.ready')
    $job=Start-Job -ArgumentList $port,$Protocol,$Scenario,$ready -ScriptBlock {
        param($port,$protocol,$scenario,$ready)
        $ErrorActionPreference='Stop'
        $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/");$listener.Start()
        [IO.File]::WriteAllText($ready,'ready')
        $requests=[Collections.Generic.List[object]]::new()
        function Send($Value,[switch]$MultiLine) {
            $json=if ($Value -is [string]) {$Value} else {$Value | ConvertTo-Json -Depth 50 -Compress}
            if ($MultiLine) {
                $comma=$json.IndexOf(',');$data=$json.Substring(0,$comma+1)+"`r`ndata: "+$json.Substring($comma+1)
            } else {$data=$json}
            $wire=": heartbeat`r`nevent: provider-event`r`nid: ignore-me`r`ndata: $data`r`n`r`n"
            $bytes=[Text.Encoding]::UTF8.GetBytes($wire)
            # Small writes split UTF-8 characters and JSON tokens across network buffers.
            for ($offset=0;$offset -lt $bytes.Length;$offset+=13) {$context.Response.OutputStream.Write($bytes,$offset,[Math]::Min(13,$bytes.Length-$offset))}
            $context.Response.OutputStream.Flush()
        }
        try {
            $count=if ($scenario -in @('Normal','Cli')) {2} elseif ($scenario -eq 'Retry') {3} else {1}
            for ($step=0;$step -lt $count;$step++) {
                $context=$listener.GetContext()
                $context.Response.KeepAlive=$false
                $reader=[IO.StreamReader]::new($context.Request.InputStream,[Text.Encoding]::UTF8)
                $body=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable;$reader.Dispose()
                $requests.Add(@{path=$context.Request.Url.AbsolutePath;session=$context.Request.Headers['x-opencode-session'];auth=$context.Request.Headers['Authorization'];body=$body})
                if ($scenario -eq 'Retry' -and $step -eq 0) {$context.Response.StatusCode=429;$context.Response.Close();continue}
                if ($scenario -eq 'Json') {
                    $context.Response.ContentType='application/json'
                    $bytes=[Text.Encoding]::UTF8.GetBytes('{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"JSON complete","reasoning_content":"JSON reasoning"}}]}')
                    $context.Response.ContentLength64=$bytes.Length;$context.Response.OutputStream.Write($bytes,0,$bytes.Length);$context.Response.Close();continue
                }
                $context.Response.ContentType='text/event-stream; charset=utf-8';$context.Response.SendChunked=$true
                $first=if ($scenario -eq 'Retry') {$step -eq 1} else {$step -eq 0}
                $reason=if ($first) {'Think €'} else {'Check €'}
                switch ($protocol) {
                    Chat {Send @{choices=@(@{index=0;delta=@{reasoning=$reason;reasoning_content=$reason};finish_reason=$null})} -MultiLine}
                    Messages {
                        Send @{type='message_start';message=@{id='msg';role='assistant';content=@();usage=@{input_tokens=1}}}
                        Send @{type='content_block_start';index=0;content_block=@{type='thinking';thinking='';signature=''}}
                        Send @{type='content_block_delta';index=0;delta=@{type='thinking_delta';thinking=$reason}} -MultiLine
                    }
                    Responses {Send @{type='response.reasoning_summary_text.delta';delta=$reason}}
                }
                Start-Sleep -Milliseconds $(if ($scenario -in @('Cancel','Timeout')) {5000} else {600})
                if ($scenario -eq 'Broken') {$context.Response.Close();break}
                if ($scenario -eq 'Malformed') {Send '{broken';$context.Response.Close();break}
                $text=if ($first) {'Ready €'} else {'Done €'}
                switch ($protocol) {
                    Chat {foreach ($piece in @($text.Substring(0,1),$text.Substring(1))) {Send @{choices=@(@{index=0;delta=@{content=$piece};finish_reason=$null})}}}
                    Messages {
                        Send @{type='content_block_delta';index=0;delta=@{type='signature_delta';signature='sig-'}}
                        Send @{type='content_block_delta';index=0;delta=@{type='signature_delta';signature='opaque'}}
                        Send @{type='content_block_stop';index=0}
                        Send @{type='content_block_start';index=1;content_block=@{type='text';text=''}}
                        foreach ($piece in @($text.Substring(0,1),$text.Substring(1))) {Send @{type='content_block_delta';index=1;delta=@{type='text_delta';text=$piece}}}
                        Send @{type='content_block_stop';index=1}
                    }
                    Responses {foreach ($piece in @($text.Substring(0,1),$text.Substring(1))) {Send @{type='response.output_text.delta';delta=$piece}}}
                }
                $arguments=@{command="Write-Output 'tool-first'; Start-Sleep -Milliseconds 600; Write-Output 'tool-last'"} | ConvertTo-Json -Compress
                if ($first) {
                    $split=[int]($arguments.Length/2);$a=$arguments.Substring(0,$split);$b=$arguments.Substring($split)
                    switch ($protocol) {
                        Chat {
                            Send @{choices=@(@{index=0;delta=@{tool_calls=@(@{index=0;id='call-stream';type='function';function=@{name='powershell';arguments=$a}})};finish_reason=$null})}
                            Send @{choices=@(@{index=0;delta=@{tool_calls=@(@{index=0;function=@{arguments=$b}})};finish_reason=$null})}
                        }
                        Messages {
                            Send @{type='content_block_start';index=2;content_block=@{type='tool_use';id='call-stream';name='powershell';input=@{}}}
                            foreach ($piece in @($a,$b)) {Send @{type='content_block_delta';index=2;delta=@{type='input_json_delta';partial_json=$piece}}}
                            Send @{type='content_block_stop';index=2}
                        }
                        Responses {foreach ($piece in @($a,$b)) {Send @{type='response.function_call_arguments.delta';output_index=2;delta=$piece}}}
                    }
                }
                Start-Sleep -Milliseconds 200
                $finish=if ($first) {'tool_calls'} else {'stop'}
                if ($scenario -eq 'Length') {$finish='length'}
                switch ($protocol) {
                    Chat {Send @{choices=@(@{index=0;delta=@{};finish_reason=$finish})};Send '[DONE]'}
                    Messages {
                        Send @{type='message_delta';delta=@{stop_reason=$(if ($first) {'tool_use'} else {'end_turn'})};usage=@{output_tokens=10}}
                        Send @{type='message_stop'}
                    }
                    Responses {
                        $output=@(@{type='reasoning';id='r';summary=@(@{type='summary_text';text=$reason});encrypted_content='opaque'},@{type='message';id='m';role='assistant';content=@(@{type='output_text';text=$text})})
                        if ($first) {$output+=@{type='function_call';id='fc';call_id='call-stream';name='powershell';arguments=$arguments}}
                        Send @{type='response.completed';response=@{id='resp';status='completed';output=$output}}
                    }
                }
                $context.Response.Close()
            }
            @{requests=$requests.ToArray()}
        } finally {Start-Sleep -Milliseconds 500;$listener.Stop();$listener.Close()}
    }
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while (-not [IO.File]::Exists($ready)) {if ([datetime]::UtcNow -gt $deadline) {Stop-Job $job;Remove-Job $job -Force;throw 'SSE server startup failed.'};Start-Sleep -Milliseconds 100}
    @{job=$job;uri="http://127.0.0.1:$port/v1"}
}
function Stop-Server($Server) {Stop-Job $Server.job;Remove-Job $Server.job -Force}
try {
    foreach ($protocol in @('Chat','Messages','Responses')) {
        $server=Start-Server $protocol
        try {
            $agent=New-GoAgent -Model test -Protocol $protocol -Workspace $root -Permission Auto -BaseUri $server.uri -TimeoutSeconds 15
            $events=[Collections.Generic.List[object]]::new()
            $onEvent={param($event) $events.Add(@{event=$event;time=[datetime]::UtcNow})}.GetNewClosure()
            $session=Join-Path $root "$protocol.session.json"
            $answer=Invoke-GoAgent $agent 'stream test' -OnEvent $onEvent -SessionPath $session
            $null=Wait-Job $server.job -Timeout 10;$capture=Receive-Job $server.job -ErrorAction Stop
            Assert ($answer -eq 'Done €') "$protocol assembled final text"
            $reasoning=@($events | Where-Object {$_.event.type -eq 'reasoning_delta'})
            $texts=@($events | Where-Object {$_.event.type -eq 'text_delta'})
            Assert (($reasoning | ForEach-Object {$_.event.delta}) -join '' -eq 'Think €Check €') "$protocol reasoning is separate and not duplicated"
            Assert (($texts | ForEach-Object {$_.event.delta}) -join '' -eq 'Ready €Done €') "$protocol UTF-8 text deltas assembled"
            Assert (($texts[0].time-$reasoning[0].time).TotalMilliseconds -ge 400) "$protocol reasoning callback fires before later network data"
            Assert (@($events | Where-Object {$_.event.type -eq 'tool_call_delta'}).Count -eq 2) "$protocol split tool arguments emitted"
            $start=@($events | Where-Object {$_.event.type -eq 'tool_start'})[0]
            $assistantEnd=@($events | Where-Object {$_.event.type -eq 'assistant_end'})[0]
            Assert ($start.time -ge $assistantEnd.time) "$protocol tool only runs after response completion"
            $updates=@($events | Where-Object {$_.event.type -eq 'tool_output_delta'})
            $end=@($events | Where-Object {$_.event.type -eq 'tool_end'})[0]
            Assert ($updates.Count -ge 2 -and $updates[0].event.delta.Contains('tool-first') -and $updates[0].time -lt $end.time) "$protocol streams command output during execution"
            Assert ($capture.requests.Count -eq 2 -and $capture.requests[0].body.stream -and $capture.requests[1].session -eq $agent.Id -and $capture.requests[0].auth -eq 'Bearer mock-stream-key') "$protocol stream flag and stable session/auth"
            $second=$capture.requests[1].body | ConvertTo-Json -Depth 100
            Assert ($second.Contains('call-stream') -and $second.Contains('tool-last')) "$protocol tool results replayed"
            switch ($protocol) {
                Chat {Assert ($agent.History[1].raw.reasoning_content -eq 'Think €') 'Chat reasoning replay field retained'}
                Messages {Assert ($agent.History[1].raw[0].signature -eq 'sig-opaque') 'Messages thinking signature retained'}
                Responses {Assert ($agent.History[1].raw[0].encrypted_content -eq 'opaque') 'Responses encrypted reasoning item retained'}
            }
            Assert (-not (($reasoning | ForEach-Object {$_.event.delta}) -join '').Contains('opaque')) "$protocol opaque signatures never rendered"
            $loaded=Import-GoSession $session
            Assert ($loaded.Id -eq $agent.Id -and $loaded.History.Count -eq 4) "$protocol complete streamed conversation saves and resumes"
        } finally {Stop-Server $server}
    }
    foreach ($protocol in @('Chat','Messages','Responses')) {
        $server=Start-Server $protocol Broken
        try {
            $a=New-GoAgent -Model test -Protocol $protocol -Workspace $root -Permission Auto -BaseUri $server.uri -TimeoutSeconds 10
            $failed=$false
            try {Invoke-GoAgent $a 'test'} catch {$failed=$true}
            Assert ($failed -and $a.History.Count -eq 0 -and -not $a.Busy) "$protocol premature EOF discards partial response and never executes tools"
        } finally {Stop-Server $server}
    }
    foreach ($scenario in @('Malformed','Length','Cancel','Timeout','Json','Retry')) {
        $server=Start-Server Chat $scenario
        $cts=[Threading.CancellationTokenSource]::new()
        try {
            $a=New-GoAgent -Model test -Protocol Chat -Workspace $root -Permission Auto -BaseUri $server.uri -TimeoutSeconds 10
            $events=[Collections.Generic.List[object]]::new();$callback={param($e) $events.Add($e)}.GetNewClosure()
            if ($scenario -eq 'Cancel') {$cts.CancelAfter(300)}
            if ($scenario -eq 'Timeout') {$a.TimeoutSeconds=1}
            $failed=$false;$answer=$null
            try {$answer=Invoke-GoAgent $a 'test' -OnEvent $callback -CancellationToken $cts.Token} catch {$failed=$true}
            if ($scenario -in @('Malformed','Length','Cancel','Timeout')) {Assert ($failed -and $a.History.Count -eq 0 -and -not $a.Busy) "$scenario stream failure rolls back incomplete exchange"}
            elseif ($scenario -eq 'Json') {Assert ($answer -eq 'JSON complete' -and @($events | Where-Object type -EQ text_delta).Count -eq 1) 'JSON fallback emits exactly one complete text event'}
            else {
                $null=Wait-Job $server.job -Timeout 10;$capture=Receive-Job $server.job -ErrorAction Stop
                Assert ($answer -eq 'Done €' -and $capture.requests.Count -eq 3 -and @($events | Where-Object type -EQ reasoning_delta).Count -eq 2) '429 retries before streaming without duplicating deltas'
            }
        } finally {$cts.Dispose();Stop-Server $server}
    }
    foreach ($hide in @($false,$true)) {
        $server=Start-Server Chat Cli
        try {
            $cli=Join-Path $PSScriptRoot '../Start-GoAgent.ps1'
            $executable=Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})
            $options=@('-NoProfile','-File',$cli,'-Model','test','-Protocol','Chat','-Workspace',$root,'-Permission','Auto','-BaseUri',$server.uri,'-Prompt','CLI stream test')
            if ($hide) {$options+='-HideReasoning'}
            $display=(& $executable @options | Out-String)
            Assert ($LASTEXITCODE -eq 0 -and @([regex]::Matches($display,'Done €')).Count -eq 1 -and @([regex]::Matches($display,'tool-first')).Count -eq 1 -and $display.Contains('[tool: powershell]')) 'CLI displays streamed final answer and tool output exactly once'
            Assert ($display.Contains('Think €') -eq (-not $hide)) 'CLI HideReasoning controls display only'
        } finally {Stop-Server $server}
    }
    $updates=[Collections.Generic.List[string]]::new()
    $callback={param($e) $updates.Add($e.text)}.GetNewClosure()
    $a=New-GoAgent -Workspace $root -Permission Auto
    $command='$bytes=[Text.Encoding]::UTF8.GetBytes("€");$stream=[Console]::OpenStandardOutput();$stream.Write($bytes,0,1);$stream.Flush();Start-Sleep -Milliseconds 500;$stream.Write($bytes,1,2);$stream.Flush();[Console]::Error.Write("stderr-live");Start-Sleep -Milliseconds 300'
    $r=Invoke-GoTool $a powershell @{command=$command} -OnUpdate $callback
    $output=$updates -join ''
    Assert (-not $r.isError -and $output.Contains('€') -and $output.Contains('stderr-live') -and -not $output.Contains([char]0xFFFD)) 'tool streaming preserves partial UTF-8 bytes and includes stderr'
    $a=New-GoAgent -Model test -Protocol Chat -Workspace $root -ReasoningEffort High
    $request=& $module {param($a) New-GoRequest $a $true} $a
    Assert ($request.Body.reasoning_effort -eq 'high' -and $request.Body.stream) 'Chat optional reasoning effort sent'
    $a=New-GoAgent -Model test -Protocol Messages -Workspace $root -ThinkingBudget 2048
    $request=& $module {param($a) New-GoRequest $a $true} $a
    Assert ($request.Body.thinking.type -eq 'enabled' -and $request.Body.thinking.budget_tokens -eq 2048) 'Messages optional thinking budget sent'
    $a=New-GoAgent -Model test -Protocol Responses -Workspace $root -ReasoningEffort Medium
    $request=& $module {param($a) New-GoRequest $a $true} $a
    Assert ($request.Body.reasoning.summary -eq 'auto' -and $request.Body.include -contains 'reasoning.encrypted_content') 'Responses requests reasoning summary and replay metadata'
    $path=Join-Path $root thinking.session.json;Save-GoSession $a $path;$loaded=Import-GoSession $path
    Assert ($loaded.ReasoningEffort -eq 'Medium') 'reasoning settings survive resume'
    $failed=$false
    try {New-GoAgent -Workspace $root -ThinkingBudget 8192 -MaxTokens 8192} catch {$failed=$true}
    Assert $failed 'thinking budget must fit within output token budget'
    $result=& $module {
        $state=New-GoStreamState Chat
        Add-GoStreamEvent $state '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"ls","arguments":"{"}},{"index":0,"id":"a","function":{"name":"read","arguments":"{\"path\":"}}]}}]}' $null
        Add-GoStreamEvent $state '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}},{"index":1,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}' $null
        Add-GoStreamEvent $state '[DONE]' $null
        Complete-GoStream $state
    }
    Assert ($result.choices[0].message.tool_calls.Count -eq 2 -and $result.choices[0].message.tool_calls[0].id -eq 'a' -and $result.choices[0].message.tool_calls[1].function.arguments -eq '{}') 'interleaved Chat tool deltas assembled by index'
    # Parser must handle a valid UTF-8 data event without an extra blank line at EOF.
    $wire="data: {`"choices`":[{`"index`":0,`"delta`":{`"content`":`"ok`"},`"finish_reason`":`"stop`"}]}`n`ndata: [DONE]"
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($wire))
    try {$result=& $module {param($s) Read-GoSseResponse $s Chat ([Threading.CancellationToken]::None) $null} $stream;Assert ($result.choices[0].message.content -eq 'ok') 'SSE final event without blank separator'} finally {$stream.Dispose()}
    # Renderer hides reasoning only on screen and never repeats streamed tool output.
    . (Join-Path $PSScriptRoot '../Console.ps1')
    $renderer=New-GoConsoleRenderer -HideReasoning
    $rendered=& {
        & $renderer @{type='assistant_start'}
        & $renderer @{type='reasoning_delta';delta='hidden reasoning'}
        & $renderer @{type='text_delta';delta='visible text'}
        & $renderer @{type='assistant_end'}
        & $renderer @{type='tool_start';name='powershell';callId='c'}
        & $renderer @{type='tool_output_delta';callId='c';delta='once-only'}
        & $renderer @{type='tool_end';name='powershell';callId='c';text='once-only';details=@{exitCode=0};isError=$false}
    } 6>&1 | Out-String
    Assert ($rendered.Contains('visible text') -and -not $rendered.Contains('hidden reasoning') -and @([regex]::Matches($rendered,'once-only')).Count -eq 1) 'console separates channels, hides reasoning and avoids duplicate tool output'
    Write-Host "All $script:passed streaming assertions passed."
} finally {$env:OPENCODE_API_KEY=$oldKey;Remove-Item -LiteralPath $root -Recurse -Force}
