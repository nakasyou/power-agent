$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('mcp-http-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$ready=Join-Path $root 'ready';$agent=$null
$job=Start-Job -ArgumentList $port,$ready -ScriptBlock {
    param($port,$ready)
    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/");$listener.Start();Set-Content $ready ready
    try {
        for ($i=0;$i -lt 5;$i++) {
            $ctx=$listener.GetContext();$reader=[IO.StreamReader]::new($ctx.Request.InputStream);$request=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable;$reader.Dispose()
            if ($i -gt 0 -and $ctx.Request.Headers['Mcp-Session-Id'] -ne 'mock-session') {throw 'Session header missing'}
            if ($request.method -eq 'notifications/initialized') {$ctx.Response.StatusCode=202;$ctx.Response.Close();continue}
            $result=switch ($request.method) {
                initialize {$ctx.Response.AddHeader('Mcp-Session-Id','mock-session');@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='http';version='1'}}}
                'tools/list' {if (-not $request.params.ContainsKey('cursor')) {@{tools=@();nextCursor='next'}} else {@{tools=@(@{name='echo';description='Echo';inputSchema=@{type='object';properties=@{text=@{type='string'}}}})}}}
                'tools/call' {@{content=@(@{type='text';text=$request.params.arguments.text});isError=$false}}
            }
            $json=@{jsonrpc='2.0';id=$request.id;result=$result} | ConvertTo-Json -Depth 30 -Compress
            if ($request.method -eq 'tools/call') {$ctx.Response.ContentType='text/event-stream';$json="data: $json`n`n"} else {$ctx.Response.ContentType='application/json'}
            $bytes=[Text.Encoding]::UTF8.GetBytes($json);$ctx.Response.OutputStream.Write($bytes,0,$bytes.Length);$ctx.Response.Close()
        }
    } finally {$listener.Close()}
}
try {
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path $ready)) {if ([datetime]::UtcNow -gt $deadline) {throw 'Startup timeout'};Start-Sleep -Milliseconds 50}
    $config=Join-Path $root 'mcp.json';@{mcpServers=@{http=@{url="http://127.0.0.1:$port/mcp"}}} | ConvertTo-Json -Depth 20 | Set-Content $config
    $agent=New-GoAgent -Workspace $root -Permission Auto -GlobalConfigDirectory $root
    Connect-GoMcp $agent -ConfigPath $config
    $result=Invoke-GoTool $agent mcp_http_echo @{text='HTTP MCP café'}
    if ($result.isError -or $result.text -ne 'HTTP MCP café') {throw "HTTP MCP failed: $($result.text)"}
    $null=Wait-Job $job -Timeout 5;Receive-Job $job -ErrorAction Stop
    Write-Host 'PASS: HTTP MCP session headers, notifications, pagination and SSE tool response'
} finally {if ($agent) {Disconnect-GoMcp $agent};Stop-Job $job;Remove-Job $job -Force;Remove-Item $root -Recurse -Force}
