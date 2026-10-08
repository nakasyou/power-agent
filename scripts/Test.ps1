#requires -Version 7.2
$ErrorActionPreference='Stop'
$executable=(Get-Process -Id $PID).Path
foreach ($test in Get-ChildItem (Join-Path $PSScriptRoot '../tests') -Filter '*.ps1' -File | Sort-Object Name) {
    Write-Host "Running $($test.Name)" -ForegroundColor Cyan
    $output=& $executable -NoProfile -File $test.FullName 2>&1 | Tee-Object -Variable captured
    $output | ForEach-Object {Write-Host $_}
    if ($LASTEXITCODE -ne 0) {
        $message=(@($captured | Select-Object -Last 40) | ForEach-Object {"$_"}) -join "`n"
        $message=$message.Replace('%','%25').Replace("`r",'%0D').Replace("`n",'%0A')
        Write-Host ("::error file=tests/{0}::{1}" -f $test.Name,$message)
        throw "Failed: $($test.Name)"
    }
}
