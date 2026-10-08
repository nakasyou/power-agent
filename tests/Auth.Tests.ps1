$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$module=Get-Module PSGoAgent
$root=Join-Path ([IO.Path]::GetTempPath()) ('auth-'+[guid]::NewGuid())
try {
    $claims=@{'https://api.openai.com/auth'=@{chatgpt_account_id='test-account'}} | ConvertTo-Json -Compress
    $jwt='header.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.signature'
    $requests=[Collections.Generic.List[object]]::new();$state=@{polls=0}
    $mock={param($Uri,$Body,$ContentType)
        $requests.Add(@{Uri=$Uri;Body=$Body;ContentType=$ContentType})
        if ($Uri.EndsWith('/usercode')) {return @{Status=200;Body=@{device_auth_id='device';user_code='CODE';interval='1'}}}
        if ($Uri.EndsWith('/deviceauth/token')) {$state.polls++;if ($state.polls -eq 1) {return @{Status=403;Body=@{}}};return @{Status=200;Body=@{authorization_code='code';code_verifier='verifier'}}}
        @{Status=200;Body=@{access_token=$jwt;refresh_token='private-refresh';expires_in=3600}}
    }.GetNewClosure()
    $codes=[Collections.Generic.List[object]]::new()
    $result=Connect-GoCodex -GlobalConfigDirectory $root -Request $mock -OnCode {$codes.Add($args[0])}
    if (-not $result.LoggedIn -or $codes[0].Url -ne 'https://auth.openai.com/codex/device' -or $state.polls -ne 2) {throw 'Device login failed'}
    if ($requests[3].Body.code_verifier -ne 'verifier' -or $requests[3].ContentType -ne 'application/x-www-form-urlencoded') {throw 'Invalid authorization exchange'}
    $agent=New-GoAgent -Provider Codex -Model gpt-5.3-codex -GlobalConfigDirectory $root -Workspace $PSScriptRoot
    $request=& $module {param($a) New-GoRequest $a} $agent
    if ($request.Uri -ne 'https://chatgpt.com/backend-api/codex/responses' -or $request.Headers['chatgpt-account-id'] -ne 'test-account' -or -not $request.Body.stream -or $request.Body.ContainsKey('max_output_tokens')) {throw 'Codex routing/body incorrect'}
    if ($request.Headers.Accept -ne 'text/event-stream') {throw 'Codex SSE Accept header missing'}
    $session=Join-Path $root 'state.session.json';Save-GoSession $agent $session
    if ((Get-Content $session -Raw).Contains('private-refresh') -or (Get-Content $session -Raw).Contains($jwt)) {throw 'Tokens leaked into session'}
    $credential=& $module {param($dir) Read-GoCodexCredential $dir} $root
    $credential.ExpiresAt=0
    & $module {param($dir,$data) Save-GoCodexCredential $dir $data} $root $credential
    $fresh=& $module {param($dir,$req) Get-GoCodexCredential $dir $req} $root $mock
    if ($fresh.ExpiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $requests[$requests.Count-1].Body.grant_type -ne 'refresh_token') {throw 'Automatic refresh failed'}
    if (-not $IsWindows -and ([IO.File]::GetUnixFileMode((Join-Path $root 'codex-auth.json')) -band ([IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::OtherRead))) {throw 'Credentials are not private'}
    Disconnect-GoCodex $root
    if (Test-Path (Join-Path $root 'codex-auth.json')) {throw 'Logout did not delete credentials'}
    Write-Host 'PASS: device authorization, pending polling, exchange, private storage, refresh, routing and logout'
} finally {if (Test-Path $root) {Remove-Item $root -Recurse -Force}}
