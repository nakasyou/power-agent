#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../PSGoAgent.psd1') -Force
$script:passed=0
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('psgo-tools-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($root)
$agent=New-GoAgent -Workspace $root -Permission Auto
$module=Get-Module PSGoAgent
function Tool([string]$Name,$Arguments) {Invoke-GoTool $agent $Name $Arguments}
function Put([string]$Path,[string]$Text) {$full=Join-Path $root $Path;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full));[IO.File]::WriteAllText($full,$Text)}
function Text([string]$Path) {[IO.File]::ReadAllText((Join-Path $root $Path))}
function Assert-Patch([string]$Before,[string]$After,[string]$Patch) {
    $old=@([regex]::Matches($Before,'[^\n]*\n|[^\n]+') | ForEach-Object Value)
    $lines=$Patch.Split("`n");$index=0;$builder=[Text.StringBuilder]::new();$hunks=0
    for ($i=2;$i -lt $lines.Count;$i++) {
        if ($lines[$i] -notmatch '^@@ -(\d+),(\d+) \+(\d+),(\d+) @@$') {continue}
        $start=[int]$Matches[1];$oldCount=[int]$Matches[2];$newCount=[int]$Matches[4]
        $target=if ($oldCount -eq 0) {$start} else {$start-1}
        while ($index -lt $target) {$null=$builder.Append($old[$index]);$index++}
        $consumed=0;$produced=0;$hunks++
        for ($i++;$i -lt $lines.Count -and -not $lines[$i].StartsWith('@@ ');$i++) {
            if (-not $lines[$i] -or $lines[$i].StartsWith('\ ')) {continue}
            $kind=$lines[$i][0];$body=$lines[$i].Substring(1)+"`n"
            if ($i+1 -lt $lines.Count -and $lines[$i+1] -eq '\ No newline at end of file') {$body=$body.TrimEnd([char]10)}
            if ($kind -ne '+') {
                if ($index -ge $old.Count -or $old[$index] -cne $body) {throw 'Patch source/context mismatch'}
                $index++;$consumed++
            }
            if ($kind -ne '-') {$null=$builder.Append($body);$produced++}
        }
        $i--
        if ($consumed -ne $oldCount -or $produced -ne $newCount) {throw 'Patch hunk count mismatch'}
    }
    while ($index -lt $old.Count) {$null=$builder.Append($old[$index]);$index++}
    Assert ($hunks -gt 0 -and $builder.ToString() -ceq $After) 'unified patch recreates edited file'
}
try {
    $names=@(Get-GoTools | ForEach-Object name)
    Assert (($names | Sort-Object) -join ',' -eq 'edit,find,grep,ls,powershell,read,write') 'seven Pi-style tool declarations'
    $readonly=New-GoAgent -Workspace $root -Permission ReadOnly
    Assert ((@(Get-GoTools $readonly | ForEach-Object name) | Sort-Object) -join ',' -eq 'find,grep,ls,read') 'read-only exposes only safe tools'
    Put edit.txt "first`nsecond`nthird`n"
    $before=Text edit.txt
    $r=Tool edit @{path='edit.txt';edits=@(@{oldText='first';newText='second'},@{oldText='second';newText='fourth'})}
    Assert (-not $r.isError -and (Text edit.txt) -ceq "second`nfourth`nthird`n") 'batch matches original, not intermediate content'
    Assert ($r.details.firstChangedLine -eq 1 -and $r.details.diff.Contains('+2 fourth')) 'edit returns line-numbered diff and first changed line'
    Assert-Patch $before (Text edit.txt) $r.details.patch
    Put edit.txt 'abcdef'
    foreach ($edits in @(
        @(@{oldText='abc';newText='X'},@{oldText='missing';newText='Y'}),
        @(@{oldText='abc';newText='X'},@{oldText='bc';newText='Y'}),
        @(@{oldText='abc';newText='X'},@{oldText='abc';newText='Y'})
    )) {
        $r=Tool edit @{path='edit.txt';edits=$edits}
        Assert ($r.isError -and (Text edit.txt) -ceq 'abcdef') 'missing/overlapping/duplicate batch leaves file unchanged'
    }
    $r=Tool edit @{path='edit.txt';edits=@(@{oldText='abc';newText='abc'})}
    Assert $r.isError 'no-op edit rejected'
    $r=Tool edit @{path='edit.txt';edits=@(@{oldText='';newText='x'})}
    Assert $r.isError 'empty oldText rejected'
    $r=Tool edit @{path='edit.txt';edits=@()}
    Assert $r.isError 'empty batch rejected'
    $r=Tool edit @{path='edit.txt';edits='[{"oldText":"abc","newText":"ABC"}]'}
    Assert (-not $r.isError -and (Text edit.txt) -ceq 'ABCdef') 'JSON string edit array normalized'
    $r=Tool edit @{path='edit.txt';edits=@{oldText='def';newText='DEF'}}
    Assert (-not $r.isError -and (Text edit.txt) -ceq 'ABCDEF') 'single edit object normalized'
    $r=Tool edit @{path='edit.txt';oldText='ABC';newText='abc'}
    Assert (-not $r.isError) 'legacy edit arguments accepted'
    Put fuzzy.txt "untouched ’ –  `nvalue = `“old`”   `nother ’  `n"
    $r=Tool edit @{path='fuzzy.txt';edits=@(@{oldText='value = "old"';newText='value = "new"'})}
    Assert (-not $r.isError -and (Text fuzzy.txt) -ceq "untouched ’ –  `nvalue = `"new`"`nother ’  `n") 'fuzzy edit normalizes touched lines only'
    Put fuzzy.txt "value = `“old`”`nvalue = `"old`""
    $r=Tool edit @{path='fuzzy.txt';edits=@(@{oldText='value = "old"';newText='new'})}
    Assert $r.isError 'normalized duplicate is ambiguous even with one exact match'
    Put fuzzy.txt "same ’  `ntarget = `“old`”`nsame ’  `nexact=one`n"
    $r=Tool edit @{path='fuzzy.txt';edits=@(@{oldText='target = "old"';newText='target = "new"'},@{oldText='exact=one';newText='exact=two'})}
    Assert (-not $r.isError -and (Text fuzzy.txt) -ceq "same ’  `ntarget = `"new`"`nsame ’  `nexact=two`n") 'mixed exact and fuzzy batch preserves duplicate untouched lines'
    $bomPath=Join-Path $root bom.txt
    [IO.File]::WriteAllText($bomPath,"one`r`ntwo`r`n",[Text.UTF8Encoding]::new($true))
    $r=Tool edit @{path='bom.txt';edits=@(@{oldText="one`ntwo";newText="ONE`nTWO"})}
    $bytes=[IO.File]::ReadAllBytes($bomPath)
    Assert (-not $r.isError -and [Convert]::ToHexString($bytes,0,3) -eq 'EFBBBF' -and (Text bom.txt) -ceq "ONE`r`nTWO`r`n") 'edit preserves UTF-8 BOM and CRLF'
    if (-not $IsWindows -and [Environment]::Version.Major -ge 7) {
        [IO.File]::SetUnixFileMode($bomPath,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $r=Tool edit @{path='bom.txt';edits=@(@{oldText='ONE';newText='One'})}
        Assert (([IO.File]::GetUnixFileMode($bomPath) -band [IO.UnixFileMode]::UserExecute) -ne 0) 'atomic edit preserves executable permission'
    }
    foreach ($pair in @(@('x','y'),@("a`nb`nc","a`nB`nc"),@("a`n","a"),@("a","a`n"),@("a`nb`n","b`n"),@("a`n","a`nb`n"))) {
        $diff=& $module {param($a,$b) Get-GoDiff sample.txt $a $b} $pair[0] $pair[1]
        Assert-Patch $pair[0] $pair[1] $diff.patch
    }
    $before=(1..30 | ForEach-Object {"line $_"}) -join "`n"
    $after=$before.Replace('line 2'+"`n",'LINE 2'+"`n").Replace('line 29'+"`n",'LINE 29'+"`n")
    $diff=& $module {param($a,$b) Get-GoDiff sample.txt $a $b} $before $after
    Assert (@([regex]::Matches($diff.patch,'(?m)^@@')).Count -eq 2) 'diff uses separate context hunks for distant changes'
    Assert-Patch $before $after $diff.patch
    $r=Tool write @{path='sub/new.txt';content='café'}
    Assert (-not $r.isError -and (Text sub/new.txt) -ceq 'café') 'write creates parents and UTF-8 data'
    Put big.txt ((1..2500 | ForEach-Object {"row $_"}) -join "`n")
    $r=Tool read @{path='big.txt'}
    Assert (-not $r.isError -and $r.details.truncation.outputLines -eq 2000 -and $r.text.Contains('offset=2001')) 'read defaults to 2000 lines with continuation'
    $r=Tool read @{path='big.txt';offset=2001;limit=3}
    Assert ($r.text.StartsWith("row 2001`nrow 2002`nrow 2003") -and $r.text.Contains('offset=2004')) 'read honors offset and limit'
    $r=Tool read @{path='big.txt';offset=3000}
    Assert $r.isError 'read rejects out-of-range offset'
    Put huge.txt ('€'*20000)
    $r=Tool read @{path='huge.txt'}
    Assert ($r.details.truncation.firstLineExceedsLimit -and $r.text.Contains('powershell')) 'read handles one line over 50 KiB without partial text'
    Put bytes.txt ((1..200 | ForEach-Object {'€'*200}) -join "`n")
    $r=Tool read @{path='bytes.txt'}
    Assert ($r.details.truncation.truncatedBy -eq 'bytes' -and $r.details.truncation.outputBytes -le 51200 -and -not $r.text.Contains([char]0xFFFD)) 'read byte limit preserves UTF-8 characters'
    Put empty.txt ''
    $r=Tool read @{path='empty.txt'}
    Assert (-not $r.isError -and $r.text -eq '') 'read empty file'
    foreach ($bad in @(@{path='big.txt';limit=1.5},@{path='big.txt';limit='2'},@{path='big.txt';offset=-1})) {
        Assert (Tool read $bad).isError 'read validates integer arguments'
    }
    Put search/.gitignore "ignored/`n*.log`n!keep.log`n/root-only.txt`n"
    Put search/.ignore "skip.txt`n"
    Put search/root-only.txt 'needle';Put search/ignored/x.ps1 'needle'
    Put search/drop.log 'needle';Put search/keep.log 'Needle'
    Put search/skip.txt 'needle';Put search/.hidden.txt 'needle'
    Put search/src/a.ps1 "before`nneedle α`nafter`nneedle β"
    Put search/src/deep/b.ps1 'needle';Put search/src/root-only.txt 'needle'
    Put search/src/c.txt 'no match';Put search/src/z.json '{}'
    $r=Tool find @{path='search';pattern='*'}
    Assert (-not $r.isError -and $r.text.Contains('.hidden.txt') -and $r.text.Contains('keep.log') -and -not $r.text.Contains('drop.log') -and -not $r.text.Contains('ignored/') -and -not $r.text.Contains('skip.txt')) 'find hidden entries, ignore rules and negation'
    Assert ($r.text.Contains('src/root-only.txt') -and -not $r.text.Contains("`nroot-only.txt")) 'anchored gitignore only excludes root candidate'
    $r=Tool find @{path='search';pattern='src/**/*.ps1'}
    Assert ($r.text.Contains('src/a.ps1') -and $r.text.Contains('src/deep/b.ps1') -and -not $r.text.Contains('c.txt')) 'find recursive glob matches zero or many directories'
    $r=Tool find @{path='search';pattern='*.{ps1,json}'}
    Assert ($r.text.Contains('a.ps1') -and $r.text.Contains('z.json')) 'find brace glob'
    $r=Tool find @{path='search';pattern='*';limit=1}
    Assert ($r.details.resultLimitReached -eq 1) 'find result limit'
    $r=Tool grep @{path='search';pattern='needle';glob='*.ps1';context=1}
    Assert (-not $r.isError -and $r.text.Contains('src/a.ps1:2: needle α') -and $r.text.Contains('src/a.ps1-1- before') -and -not $r.text.Contains('ignored')) 'grep regex with glob, ignore rules and context'
    $r=Tool grep @{path='search';pattern='needle';ignoreCase=$true}
    Assert ($r.text.Contains('keep.log:1: Needle') -and -not $r.text.Contains('drop.log')) 'grep case-insensitive search'
    Put search/literal.txt 'a.b axb'
    $r=Tool grep @{path='search/literal.txt';pattern='a.b';literal=$true}
    Assert ($r.text.Contains('literal.txt:1: a.b axb')) 'grep literal pattern and explicit file'
    $r=Tool grep @{path='search';pattern='needle';limit=1}
    Assert ($r.details.matchLimitReached -eq 1) 'grep match limit'
    Put search/long.txt ('needle'+('x'*700))
    $r=Tool grep @{path='search/long.txt';pattern='needle'}
    Assert ($r.details.linesTruncated -and $r.text.Contains('[truncated]')) 'grep truncates long lines'
    [IO.File]::WriteAllBytes((Join-Path $root search/binary.txt),[byte[]]@(0,110,101,101,100,108,101))
    $r=Tool grep @{path='search/binary.txt';pattern='needle'}
    Assert ($r.text -eq 'No matches found') 'grep skips binary files'
    $r=Tool grep @{path='search';pattern='['}
    Assert $r.isError 'grep malformed regex errors'
    $r=Tool grep @{path='search';pattern='needle';ignoreCase='yes'}
    Assert $r.isError 'grep validates boolean arguments'
    $r=Tool ls @{path='search';limit=2}
    Assert ($r.details.entryLimitReached -eq 2 -and $r.text.StartsWith('.gitignore')) 'ls sorts dotfiles and applies entry limit'
    $r=Tool ls @{path='search/src'}
    Assert ($r.text.Contains('deep/')) 'ls suffixes directories'
    $r=Tool ls @{path='empty.txt'}
    Assert $r.isError 'ls rejects a file path'
    foreach ($name in @('read','write','edit','grep','find','ls')) {
        $arg=switch ($name) {'write' {@{path='../escape';content='x'}} 'edit' {@{path='../escape';edits=@(@{oldText='a';newText='b'})}} {'grep','find' -contains $_} {@{path='..';pattern='*'}} default {@{path='..'}}}
        Assert (Tool $name $arg).isError "$name rejects workspace traversal"
    }
    if (-not $IsWindows) {
        $null=New-Item -ItemType SymbolicLink -Path (Join-Path $root search/outside) -Target ([IO.Path]::GetTempPath())
        $r=Tool find @{path='search';pattern='*'}
        Assert (-not $r.text.Contains('outside')) 'search skips symlink recursion'
    }
    $r=Tool powershell @{command="Write-Output 'café'; [Console]::Error.WriteLine('stderr')"}
    Assert (-not $r.isError -and $r.text.Contains('café') -and $r.text.Contains('stderr') -and $r.details.exitCode -eq 0) 'powershell captures UTF-8 and stderr'
    $r=Tool powershell @{command='exit 7'}
    Assert ($r.isError -and $r.details.exitCode -eq 7) 'nonzero exit is an error result'
    $r=Tool powershell @{command="throw 'broken'"}
    Assert ($r.isError -and $r.text.Contains('broken')) 'PowerShell exception is an error result'
    $r=Tool powershell @{command='1..3000 | ForEach-Object { "line $_" }'}
    Assert (-not $r.isError -and $r.structuredContent.truncated -and $r.text.Contains('line 3000') -and -not $r.text.StartsWith("line 1`n") -and (Test-Path $r.details.fullOutputPath)) 'powershell retains output tail and full output file'
    $log=Tool read @{path=$r.details.fullOutputPath;offset=1;limit=1}
    Assert ($log.text.StartsWith('line 1')) 'read can inspect saved full command output'
    $r=Tool powershell @{command="[Console]::Write('€'*40000)"}
    Assert ($r.structuredContent.truncated -and -not $r.text.Contains([char]0xFFFD) -and [Text.Encoding]::UTF8.GetByteCount($r.structuredContent.output) -le 51200) 'single huge shell line truncates at UTF-8 boundaries'
    $r=Tool powershell @{command="Write-Output 'before-timeout'; Start-Sleep 10";timeout=0.7}
    Assert ($r.isError -and $r.text.Contains('before-timeout') -and $r.text.Contains('timed out')) 'fractional timeout keeps partial output'
    foreach ($timeout in @(0,-1,'1',[double]::NaN)) {Assert (Tool powershell @{command='1';timeout=$timeout}).isError 'powershell rejects invalid timeout'}
    $updates=[Collections.Generic.List[object]]::new()
    $onUpdate={param($update) $updates.Add(@{text=$update.text;time=[datetime]::UtcNow})}.GetNewClosure()
    $started=[datetime]::UtcNow
    $r=Invoke-GoTool $agent powershell @{command="Write-Output 'first'; Start-Sleep 2; Write-Output 'last'"} -OnUpdate $onUpdate
    Assert (-not $r.isError -and $updates.Count -ge 2 -and ($updates[0].time-$started).TotalSeconds -lt 1.8) 'shell emits updates before command completion'
    $cts=[Threading.CancellationTokenSource]::new();$cts.CancelAfter(800)
    $r=Invoke-GoTool $agent powershell @{command="Write-Output 'before-cancel'; Start-Sleep 10"} -CancellationToken $cts.Token
    Assert ($r.isError -and $r.text.Contains('Command aborted')) 'cancellation stops running command'
    $cts.Dispose()
    $cts=[Threading.CancellationTokenSource]::new();$cts.Cancel()
    $r=Invoke-GoTool $agent write @{path='cancelled.txt';content='x'} -CancellationToken $cts.Token
    Assert ($r.isError -and -not (Test-Path (Join-Path $root cancelled.txt))) 'cancelled mutation writes nothing'
    $cts.Dispose()
    $oldKey=$env:OPENCODE_API_KEY
    try {
        $env:OPENCODE_API_KEY='do-not-pass-this-key'
        $r=Tool powershell @{command='[bool]$env:OPENCODE_API_KEY; $env:PI_SESSION_ID; $env:PI_MODEL_ID'}
        Assert ($r.text.Contains('False') -and $r.text.Contains($agent.Id) -and -not $r.text.Contains('do-not-pass-this-key')) 'child receives session metadata and no provider credential'
    } finally {$env:OPENCODE_API_KEY=$oldKey}
    $png=[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ3sAAAAASUVORK5CYII=')
    [IO.File]::WriteAllBytes((Join-Path $root tiny.png),$png)
    $r=Tool read @{path='tiny.png'}
    Assert (-not $r.isError -and $r.content[1].type -eq 'image' -and $r.content[1].mimeType -eq 'image/png' -and $r.content[1].data -eq [Convert]::ToBase64String($png)) 'read returns structured PNG attachment'
    foreach ($protocol in @('Chat','Messages','Responses')) {
        $a=New-GoAgent -Model test -Protocol $protocol -Workspace $root -EnableImages
        $a.History.Add(@{kind='user';text='image test'})
        $raw=switch ($protocol) {
            Chat {@{role='assistant';content=$null;tool_calls=@(@{id='img';type='function';function=@{name='read';arguments='{"path":"tiny.png"}'}})}}
            Messages {@(@{type='tool_use';id='img';name='read';input=@{path='tiny.png'}})}
            Responses {@(@{type='function_call';call_id='img';name='read';arguments='{"path":"tiny.png"}'})}
        }
        $a.History.Add(@{kind='assistant';raw=$raw})
        $a.History.Add(@{kind='result';callId='img';text=$r.text;isError=$false;content=$r.content;details=$r.details})
        $req=& $module {param($a) New-GoRequest $a} $a
        $json=$req.Body | ConvertTo-Json -Depth 100
        Assert ($json.Contains([Convert]::ToBase64String($png))) "$protocol image attachment translated to provider request"
        $path=Join-Path $root "$protocol-image.session.json"
        Save-GoSession $a $path;$loaded=Import-GoSession $path
        Assert ($loaded.EnableImages -and $loaded.History[2].content[1].data -eq [Convert]::ToBase64String($png)) "$protocol image survives session round trip"
        $a.EnableImages=$false
        $req=& $module {param($a) New-GoRequest $a} $a
        $json=$req.Body | ConvertTo-Json -Depth 100
        Assert (-not $json.Contains([Convert]::ToBase64String($png)) -and $json.Contains('Image omitted')) "$protocol omits images when disabled"
    }
    # Independent processes target the same path; the named mutation mutex must serialize them.
    Put concurrent.txt 'left=one right=one'
    $path=Join-Path $root concurrent.txt
    $mutex=& $module {param($p) Get-GoMutationMutex $p} $path
    $null=$mutex.WaitOne()
    $jobs=@()
    try {
        foreach ($side in @('left','right')) {
            $jobs+=Start-Job -ArgumentList (Join-Path $PSScriptRoot '../PSGoAgent.psd1'),$root,$side -ScriptBlock {
                param($modulePath,$root,$side)
                Import-Module $modulePath -Force
                $a=New-GoAgent -Workspace $root -Permission Auto
                [IO.File]::WriteAllText((Join-Path $root ($side+'.ready')),'ready')
                Invoke-GoTool $a edit @{path='concurrent.txt';edits=@(@{oldText=($side+'=one');newText=($side+'=two')})}
            }
        }
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while (-not ((Test-Path (Join-Path $root left.ready)) -and (Test-Path (Join-Path $root right.ready)))) {
            if ([datetime]::UtcNow -gt $deadline) {throw 'Mutation test workers did not start.'}
            Start-Sleep -Milliseconds 100
        }
        Start-Sleep -Milliseconds 200
        Assert ((Text concurrent.txt) -ceq 'left=one right=one') 'mutation mutex blocks competing writers'
    } finally {$mutex.ReleaseMutex();$mutex.Dispose()}
    try {
        $null=Wait-Job $jobs -Timeout 15
        $results=@(Receive-Job $jobs -ErrorAction Stop)
        Assert ($results.Count -eq 2 -and @($results | Where-Object isError -EQ $true).Count -eq 0 -and (Text concurrent.txt) -ceq 'left=two right=two') 'concurrent edits retain both disjoint changes'
    } finally {Stop-Job $jobs;Remove-Job $jobs -Force}
    Write-Host "All $script:passed tool assertions passed."
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
