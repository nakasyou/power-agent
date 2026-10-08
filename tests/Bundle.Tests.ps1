#requires -Version 7.2
$ErrorActionPreference='Stop'
$bundle=Join-Path $PSScriptRoot '../dist/Power-Agent.ps1'
if (-not (Test-Path $bundle)) {Write-Host 'SKIP: build the standalone bundle to run bundle tests';exit 0}
$root=Join-Path ([IO.Path]::GetTempPath()) ('bundle-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$ready=Join-Path $root 'ready'
$job=Start-Job -ArgumentList $port,$ready -ScriptBlock {
    param($port,$ready)
    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/");$listener.Start();Set-Content $ready ready
    try {
        for ($step=0;$step -lt 2;$step++) {
            $ctx=$listener.GetContext();$reader=[IO.StreamReader]::new($ctx.Request.InputStream);$request=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable;$reader.Dispose()
            if ($request.model -ne 'local' -or $ctx.Request.Headers['x-opencode-session']) {throw 'Bundle provider settings incorrect'}
            if ($step -eq 0) {$response=@{choices=@(@{finish_reason='tool_calls';message=@{role='assistant';content='Reading';tool_calls=@(@{id='read-1';type='function';function=@{name='read';arguments='{"path":"sample.txt"}'}})}})}}
            else {
                if (-not (($request | ConvertTo-Json -Depth 100).Contains('Bundle café'))) {throw 'Tool result missing from next request'}
                $response=@{choices=@(@{finish_reason='stop';message=@{role='assistant';content='Bundle completed'}})}
            }
            $ctx.Response.ContentType='application/json';$bytes=[Text.Encoding]::UTF8.GetBytes(($response | ConvertTo-Json -Depth 100 -Compress));$ctx.Response.ContentLength64=$bytes.Length;$ctx.Response.OutputStream.Write($bytes,0,$bytes.Length);$ctx.Response.Close()
        }
    } finally {$listener.Close()}
}
try {
    $standalone=Join-Path $root 'Power-Agent.ps1';Copy-Item $bundle $standalone;Set-Content (Join-Path $root 'sample.txt') 'Bundle café'
    $executable=(Get-Process -Id $PID).Path
    $version=& $executable -NoProfile -File $standalone -Version
    $expected=(Import-PowerShellDataFile (Join-Path $PSScriptRoot '../PSGoAgent.psd1')).ModuleVersion
    if ($LASTEXITCODE -ne 0 -or $version -ne $expected) {throw 'Standalone version check failed'}
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path $ready)) {if ([datetime]::UtcNow -gt $deadline) {throw 'Startup timeout'};Start-Sleep -Milliseconds 50}
    $output=& $executable -NoProfile -File $standalone -Provider OpenAI -Model local -BaseUri "http://127.0.0.1:$port/v1" -Workspace $root -SessionDirectory (Join-Path $root 'sessions') -GlobalConfigDirectory (Join-Path $root 'global') -Prompt 'Read sample.txt' -NoStream 6>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $output.Contains('Bundle completed')) {throw 'Standalone tool loop failed'}
    $files=@(Get-ChildItem (Join-Path $root 'sessions') -Filter '*.session.json')
    $state=Get-Content $files[0].FullName -Raw | ConvertFrom-Json -AsHashtable
    if ($files.Count -ne 1 -or $state.History.Count -ne 4) {throw 'Bundle session persistence failed'}
    $null=Wait-Job $job -Timeout 5;Receive-Job $job -ErrorAction Stop
    Write-Host 'PASS: isolated single-file execution, version, provider HTTP, tool loop and session persistence'
} finally {Stop-Job $job;Remove-Job $job -Force;Remove-Item $root -Recurse -Force}
