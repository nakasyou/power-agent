$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('instructions-'+[guid]::NewGuid())
try {
    $workspace=Join-Path $root 'project';$global=Join-Path $root 'global'
    foreach ($path in @($workspace,$global,(Join-Path $workspace '.git'),(Join-Path $workspace 'src'),(Join-Path $global 'skills/example'),(Join-Path $workspace '.agents/skills/example'))) {$null=New-Item -ItemType Directory -Path $path -Force}
    Set-Content (Join-Path $global 'AGENTS.md') 'Global rule'
    Set-Content (Join-Path $workspace 'AGENTS.md') 'Project rule'
    Set-Content (Join-Path $workspace 'src/AGENTS.md') 'Scoped rule'
    Set-Content (Join-Path $workspace 'src/file.txt') 'sample'
    Set-Content (Join-Path $global 'skills/example/SKILL.md') "---`nname: example`ndescription: Global skill`n---`nGlobal skill body"
    Set-Content (Join-Path $workspace '.agents/skills/example/SKILL.md') "---`nname: example`ndescription: Local skill`n---`nLocal skill body"
    $agent=New-GoAgent -Workspace $workspace -GlobalConfigDirectory $global -Permission ReadOnly
    if (-not $agent.System.Contains('Global rule') -or -not $agent.System.Contains('Project rule') -or $agent.System.Contains('Scoped rule')) {throw 'Instruction scopes incorrect'}
    $read=Invoke-GoTool $agent read @{path='src/file.txt'}
    if (-not $read.text.Contains('Scoped rule')) {throw 'Nested instructions missing'}
    $skill=Invoke-GoTool $agent skill @{name='example'}
    if ($skill.isError -or -not $skill.text.Contains('Local skill body') -or $skill.text.Contains('Global skill body')) {throw 'Local skill must override global skill'}
    $bad=Invoke-GoTool $agent skill @{name='missing'}
    if (-not $bad.isError) {throw 'Unknown skill accepted'}
    $path=Join-Path $root 'state.session.json';Save-GoSession $agent $path
    $resumed=Import-GoSession $path -GlobalConfigDirectory $global
    if (-not $resumed.Skills.ContainsKey('example')) {throw 'Resume does not rediscover skills'}
    Write-Host 'PASS: global/project/scoped instructions, local skill precedence, loading and resume'
} finally {Remove-Item $root -Recurse -Force}
