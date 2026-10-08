$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('search-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
try {
    $captured=[Collections.Generic.List[object]]::new()
    $transport={param($Request)
        $captured.Add($Request)
        @{status='completed';output=@(@{type='message';role='assistant';content=@(@{type='output_text';text='Search summary';annotations=@(@{type='url_citation';url='https://example.com/source';title='Example'})})})}
    }.GetNewClosure()
    $agent=New-GoAgent -Provider OpenAI -Model custom -EnableWebSearch -WebSearchModel search-model -Transport $transport -Workspace $root -Permission ReadOnly
    $updates=[Collections.Generic.List[object]]::new()
    $result=Invoke-GoTool $agent web_search @{query='latest news'} -OnUpdate {$updates.Add($args[0])}
    if ($result.isError -or -not $result.text.Contains('https://example.com/source') -or $result.structuredContent.sources.Count -ne 1) {throw "Search failed: $($result.text)"}
    if ($captured[0].Body.tools[0].type -ne 'web_search' -or $captured[0].Body.model -ne 'search-model' -or -not $captured[0].Uri.EndsWith('/responses')) {throw 'Search was not delegated to Responses web_search'}
    if ($agent.History.Count -or $agent.Protocol -ne 'Chat' -or $updates.Count -ne 2) {throw 'Search altered conversation or lost streamed output'}
    $path=Join-Path $root 'state.session.json';Save-GoSession $agent $path
    $resumed=Import-GoSession $path
    if (-not $resumed.EnableWebSearch -or $resumed.WebSearchModel -ne 'search-model') {throw 'Search settings not restored'}
    Write-Host 'PASS: Responses search delegation, streaming, citations, isolated history and session settings'
} finally {Remove-Item $root -Recurse -Force}
