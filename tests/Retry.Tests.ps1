#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('retry-test-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory $root
$previousKey=$env:OPENCODE_API_KEY;$env:OPENCODE_API_KEY='retry-mock-key'
$count=0
function Assert($Condition,$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
try {
    foreach ($case in @(@{name='StreamRetry';status=503;retries=1;steps=2;stream=$true},@{name='BufferedRetry';status=503;retries=1;steps=2;stream=$false},@{name='Disabled';status=503;retries=0;steps=1;stream=$true},@{name='Auth';status=401;retries=2;steps=1;stream=$true},@{name='CLI';status=200;retries=0;steps=1;stream=$false})) {
        $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
        $ready=Join-Path $root $case.name
        $job=Start-Job -ArgumentList $port,$case,$ready -ScriptBlock {
            param($port,$case,$ready)
            $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/");$listener.Start()
            [IO.File]::WriteAllText($ready,'ready')
            $requests=[Collections.Generic.List[object]]::new()
            try {
                for ($i=0;$i -lt $case.steps;$i++) {
                    $context=$listener.GetContext()
                    $reader=[IO.StreamReader]::new($context.Request.InputStream)
                    $requests.Add(($reader.ReadToEnd() | ConvertFrom-Json -AsHashtable));$reader.Dispose()
                    $context.Response.ContentType='application/json'
                    if ($i -eq 0 -and $case.status -ne 200) {$context.Response.StatusCode=$case.status;$context.Response.AddHeader('Retry-After','1');$json='{"error":"mock"}'}
                    else {$json='{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Saved successfully"}}]}'}
                    $bytes=[Text.Encoding]::UTF8.GetBytes($json);$context.Response.OutputStream.Write($bytes,0,$bytes.Length);$context.Response.Close()
                }
                @{requests=$requests.ToArray()}
            } finally {$listener.Close()}
        }
        try {
            $deadline=[datetime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path $ready)) {if ([datetime]::UtcNow -gt $deadline) {throw 'Server startup timeout'};Start-Sleep -Milliseconds 50}
            if ($case.name -eq 'CLI') {
                $sessionDir=Join-Path $root 'cli-sessions'
                $cliOutput=& (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot '../Start-GoAgent.ps1') -Workspace $root -SessionDirectory $sessionDir -BaseUri "http://127.0.0.1:$port/v1" -NoStream -Prompt 'Save the session automatically' 6>&1 | Out-String
                Assert ($LASTEXITCODE -eq 0 -and $cliOutput.Contains('Saved successfully')) 'single prompt CLI completes request'
                $files=@(Get-ChildItem $sessionDir -Filter '*.session.json')
                Assert ($files.Count -eq 1) 'CLI automatically creates session without SessionPath'
                $saved=Import-GoSession $files[0].FullName
                Assert ($saved.History.Count -eq 2 -and $saved.History[0].text -eq 'Save the session automatically') 'automatic session contains request and final answer'
            } else {
                $a=New-GoAgent -Workspace $root -BaseUri "http://127.0.0.1:$port/v1" -MaxRetries $case.retries
                $events=[Collections.Generic.List[object]]::new();$failed=$false;$answer=''
                try {$answer=Invoke-GoAgent $a 'test' -NoStream:(-not $case.stream) -OnEvent {$events.Add($args[0])}} catch {$failed=$true}
                if ($case.steps -eq 2) {
                    Assert ($answer -eq 'Saved successfully' -and -not $failed) "$($case.name) automatically resends transient failure"
                    Assert (@($events | Where-Object type -EQ retry).Count -eq 1) "$($case.name) reports retry progress"
                    Assert ($a.History.Count -eq 2) "$($case.name) does not duplicate user history"
                } else {
                    Assert ($failed -and @($events | Where-Object type -EQ retry).Count -eq 0) "$($case.name) does not retry"
                    Assert ($a.History.Count -eq 0) "$($case.name) rolls back failed request"
                }
            }
            $null=Wait-Job $job -Timeout 5;$capture=Receive-Job $job -ErrorAction Stop
            Assert ($capture.requests.Count -eq $case.steps) "$($case.name) sends exactly configured number of requests"
        } finally {Stop-Job $job;Remove-Job $job -Force}
    }
    $module=Get-Module PSGoAgent
    $cancel=[Threading.CancellationTokenSource]::new();$cancel.Cancel()
    try {
        $failed=$false
        try {& $module {param($Token) Wait-GoRetry 0 2 $Token $null} $cancel.Token} catch {$failed=$true}
        Assert $failed 'cancellation interrupts retry delay'
    } finally {$cancel.Dispose()}
    Write-Host "All $count retry assertions passed."
} finally {$env:OPENCODE_API_KEY=$previousKey;Remove-Item $root -Recurse -Force}
