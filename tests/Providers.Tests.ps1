$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$module=Get-Module PSGoAgent
$root=Join-Path ([IO.Path]::GetTempPath()) ('providers-'+[guid]::NewGuid());$null=New-Item -ItemType Directory $root
try {
    foreach ($protocol in @('Chat','Responses')) {
        $agent=New-GoAgent -Provider OpenAI -Model custom -Protocol $protocol -BaseUri 'http://127.0.0.1:34567/v1' -ApiKey 'private-test-key' -Workspace $root
        $request=& $module {param($a) New-GoRequest $a} $agent
        if ($request.Headers.Authorization -ne 'Bearer private-test-key' -or $request.Headers.ContainsKey('x-opencode-session')) {throw 'Incorrect compatible-provider headers'}
        if ($request.Body.model -ne 'custom' -or $request.Uri -notlike '*'+$(if ($protocol -eq 'Chat') {'chat/completions'} else {'responses'})) {throw 'Incorrect provider routing'}
        $path=Join-Path $root 'state.session.json';Save-GoSession $agent $path
        if ((Get-Content $path -Raw).Contains('private-test-key')) {throw 'API key leaked into session'}
        $resumed=Import-GoSession $path
        if ($resumed.Provider -ne 'OpenAI' -or $resumed.BaseUri -ne $agent.BaseUri -or $resumed.ApiKey) {throw 'Provider resume incorrect'}
        Set-GoModel $agent another-custom-model
        if ($agent.Protocol -ne 'Chat') {throw 'Unknown compatible model should route to Chat'}
    }
    $local=New-GoAgent -Provider OpenAI -Model local -BaseUri 'http://127.0.0.1:1234/v1' -Workspace $root
    if ($local.Protocol -ne 'Chat') {throw 'Compatible automatic routing failed'}
    $failed=$false;try {New-GoAgent -Provider OpenAI -Protocol Messages -Workspace $root | Out-Null} catch {$failed=$true}
    if (-not $failed) {throw 'Invalid provider protocol accepted'}
    Write-Host 'PASS: OpenAI Chat/Responses routing, headers, key isolation, persistence and model changes'
} finally {Remove-Item $root -Recurse -Force}
