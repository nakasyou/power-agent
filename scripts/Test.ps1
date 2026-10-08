#requires -Version 7.2
$ErrorActionPreference='Stop'
$executable=(Get-Process -Id $PID).Path
foreach ($test in Get-ChildItem (Join-Path $PSScriptRoot '../tests') -Filter '*.ps1' -File | Sort-Object Name) {
    Write-Host "Running $($test.Name)" -ForegroundColor Cyan
    & $executable -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) {throw "Failed: $($test.Name)"}
}
