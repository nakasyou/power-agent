$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('mcp-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
$agent=$null
try {
    $server=Join-Path $root 'server.ps1'
    @'
while ($line=[Console]::ReadLine()) {
    $request=$line | ConvertFrom-Json -AsHashtable
    if (-not $request.ContainsKey('id')) {continue}
    $result=switch ($request.method) {
        'initialize' {@{protocolVersion='2025-03-26';capabilities=@{tools=@{}};serverInfo=@{name='mock';version='1'}}}
        'tools/list' {@{tools=@(@{name='echo';description='Echo text';inputSchema=@{type='object';properties=@{text=@{type='string'}};required=@('text')}})}}
        'tools/call' {
            [Console]::WriteLine((@{jsonrpc='2.0';method='notifications/progress';params=@{message='Working';progress=1}} | ConvertTo-Json -Depth 10 -Compress))
            @{content=@(@{type='text';text=$request.params.arguments.text});structuredContent=@{echo=$request.params.arguments.text};isError=$false}
        }
    }
    [Console]::WriteLine((@{jsonrpc='2.0';id=$request.id;result=$result} | ConvertTo-Json -Depth 30 -Compress))
}
'@ | Set-Content $server
    $config=Join-Path $root 'mcp.json'
    @{mcpServers=@{test=@{command=(Get-Process -Id $PID).Path;args=@('-NoProfile','-File',$server)}}} | ConvertTo-Json -Depth 20 | Set-Content $config
    $agent=New-GoAgent -Workspace $root -GlobalConfigDirectory $root -Permission Auto
    Connect-GoMcp $agent -ConfigPath $config
    if (@(Get-GoTools $agent | Where-Object name -EQ mcp_test_echo).Count -ne 1) {throw 'Tool discovery failed'}
    $updates=[Collections.Generic.List[object]]::new()
    $result=Invoke-GoTool $agent mcp_test_echo @{text='café result'} -OnUpdate {$updates.Add($args[0])}
    if ($result.isError -or $result.text -ne 'café result' -or $result.structuredContent.echo -ne 'café result' -or $updates.Count -ne 1) {throw 'MCP invocation or progress failed'}
    $agent.Permission='ReadOnly'
    if (@(Get-GoTools $agent | Where-Object name -like 'mcp_*').Count) {throw 'ReadOnly exposes external tools'}
    if (-not (Invoke-GoTool $agent mcp_test_echo @{text='denied'}).isError) {throw 'ReadOnly invocation accepted'}
    $process=$agent.McpConnections[0].Process
    Disconnect-GoMcp $agent
    if ($agent.McpTools.Count -or $agent.McpConnections.Count) {throw 'Cleanup failed'}
    Write-Host 'PASS: real stdio MCP initialization, discovery, invocation, progress, structured result, permissions and cleanup'
} finally {if ($agent) {Disconnect-GoMcp $agent};Remove-Item $root -Recurse -Force}
