#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('psgo-http-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory $root
[IO.File]::WriteAllText((Join-Path $root 'sample.txt'),'HTTP経由テスト')
$oldKey=$env:OPENCODE_API_KEY
$env:OPENCODE_API_KEY='mock-test-key'
$count=0
try {
    foreach ($protocol in @('Chat','Messages','Responses')) {
        $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $portProbe.Start();$port=$portProbe.LocalEndpoint.Port;$portProbe.Stop()
        $ready=Join-Path $root "ready-$protocol"
        $job=Start-Job -ArgumentList $port,$protocol,$ready -ScriptBlock {
            param($port,$protocol,$ready)
            $ErrorActionPreference='Stop'
            $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start();[IO.File]::WriteAllText($ready,'ready')
            $requests=[Collections.Generic.List[object]]::new()
            $steps=if ($protocol -eq 'Chat') {3} else {2}
            try {
                for ($n=0;$n -lt $steps;$n++) {
                    $context=$listener.GetContext()
                    $reader=[IO.StreamReader]::new($context.Request.InputStream,[Text.Encoding]::UTF8)
                    $body=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable;$reader.Dispose()
                    $requests.Add(@{path=$context.Request.Url.AbsolutePath;session=$context.Request.Headers['x-opencode-session'];auth=$context.Request.Headers['Authorization'];apiKey=$context.Request.Headers['x-api-key'];version=$context.Request.Headers['anthropic-version'];body=$body})
                    if ($protocol -eq 'Chat' -and $n -eq 0) { $context.Response.StatusCode=429;$response=@{error='mock rate limit'} }
                    else {
                        $isTool=if ($protocol -eq 'Chat') {$n -eq 1} else {$n -eq 0}
                        $response=switch ($protocol) {
                            'Chat' {
                                if ($isTool) { @{choices=@(@{finish_reason='tool_calls';message=@{role='assistant';content=$null;tool_calls=@(@{id='http-call';type='function';function=@{name='read';arguments='{"path":"sample.txt"}'}})}})} }
                                else { @{choices=@(@{finish_reason='stop';message=@{role='assistant';content='HTTP完了'}})} }
                            }
                            'Messages' {
                                if ($isTool) { @{stop_reason='tool_use';content=@(@{type='tool_use';id='http-call';name='read';input=@{path='sample.txt'}})} }
                                else { @{stop_reason='end_turn';content=@(@{type='text';text='HTTP完了'})} }
                            }
                            'Responses' {
                                if ($isTool) { @{status='completed';output=@(@{type='function_call';id='fc';call_id='http-call';name='read';arguments='{"path":"sample.txt"}'})} }
                                else { @{status='completed';output=@(@{type='message';id='m';role='assistant';content=@(@{type='output_text';text='HTTP完了'})})} }
                            }
                        }
                    }
                    $bytes=[Text.Encoding]::UTF8.GetBytes(($response | ConvertTo-Json -Depth 30 -Compress))
                    $context.Response.ContentType='application/json; charset=utf-8';$context.Response.ContentLength64=$bytes.Length
                    $context.Response.OutputStream.Write($bytes,0,$bytes.Length);$context.Response.Close()
                }
                @{requests=$requests.ToArray()}
            } finally { $listener.Stop();$listener.Close() }
        }
        try {
            $deadline=[datetime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path $ready)) {
                if ([datetime]::UtcNow -gt $deadline -or $job.State -eq 'Failed') { throw 'Mock HTTP server did not start.' }
                Start-Sleep -Milliseconds 100
            }
            $agent=New-GoAgent -Model test -Protocol $protocol -Workspace $root -Permission ReadOnly -BaseUri "http://127.0.0.1:$port/v1" -TimeoutSeconds 10
            $answer=Invoke-GoAgent $agent '読み取って'
            if ($answer -ne 'HTTP完了') { throw "$protocol HTTP answer mismatch" }
            $null=Wait-Job $job -Timeout 10
            $capture=Receive-Job $job -ErrorAction Stop
            $requests=$capture.requests
            $expected=switch ($protocol) {Chat {'/v1/chat/completions'} Messages {'/v1/messages'} Responses {'/v1/responses'}}
            foreach ($request in $requests) {
                if ($request.path -ne $expected -or $request.session -ne $agent.Id -or $request.auth -ne 'Bearer mock-test-key') { throw "$protocol path/header mismatch" }
                if ($request.body.model -ne 'test' -or $request.body.stream -ne $false -or $request.body.tools.Count -ne 5) { throw "$protocol request body mismatch" }
            }
            if ($protocol -eq 'Messages' -and ($requests[0].apiKey -ne 'mock-test-key' -or $requests[0].version -ne '2023-06-01')) { throw 'Messages auth/version mismatch' }
            $last=$requests[$requests.Count-1].body | ConvertTo-Json -Depth 100
            if (-not $last.Contains('HTTP経由テスト') -or -not $last.Contains('http-call')) { throw "$protocol UTF-8 tool result missing" }
            if ($protocol -eq 'Chat' -and $requests.Count -ne 3) { throw '429 retry was not performed.' }
            $count++; Write-Host "PASS: $protocol real HTTP request, headers, UTF-8, tool loop$(if ($protocol -eq 'Chat') {', 429 retry'})"
        } finally { Stop-Job $job;Remove-Job $job -Force }
    }
    Write-Host "All $count HTTP integration scenarios passed."
} finally {
    $env:OPENCODE_API_KEY=$oldKey
    Remove-Item -LiteralPath $root -Recurse -Force
}
