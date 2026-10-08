# PowerShell-only implementations of Pi's local coding tools.
function Get-GoTools {
    param($Agent)
    $string=@{type='string'}; $positive=@{type='integer';minimum=1}; $boolean=@{type='boolean'}
    $specs=@(
        @{name='read';description='Read text or PNG/JPEG/GIF/WebP image attachments. Text is capped at 2000 lines or 50 KiB; use offset/limit to continue.';properties=@{path=$string;offset=$positive;limit=$positive};required=@('path')}
        @{name='powershell';description='Execute PowerShell in the workspace, returning stdout/stderr and exit status. Optional timeout in seconds; no default timeout. Output keeps the last 2000 lines/50 KiB, with a full output file when truncated. Not sandboxed.';properties=@{command=$string;timeout=@{type='number';exclusiveMinimum=0;maximum=2147483.647}};required=@('command')}
        @{name='edit';description='Replace unique, non-overlapping regions of the ORIGINAL file using edits[]. Use one call for disjoint changes. Preserves BOM and newline style; returns a diff and unified patch.';properties=@{path=$string;edits=@{type='array';minItems=1;items=@{type='object';properties=@{oldText=$string;newText=$string};required=@('oldText','newText');additionalProperties=$false}}};required=@('path','edits')}
        @{name='write';description='Create or overwrite a UTF-8 file, creating parent directories. Use for new files or complete rewrites.';properties=@{path=$string;content=$string};required=@('path','content')}
        @{name='grep';description='Search text files with regex or literal text. Respects .gitignore and .ignore; returns paths/line numbers, optional context. Default 100 matches/50 KiB, lines capped at 500 characters.';properties=@{pattern=$string;path=$string;glob=$string;ignoreCase=$boolean;literal=$boolean;context=@{type='integer';minimum=0};limit=$positive};required=@('pattern')}
        @{name='find';description='Find files/directories by glob; relative paths, hidden entries, .gitignore/.ignore respected. Default 1000 results/50 KiB.';properties=@{pattern=$string;path=$string;limit=$positive};required=@('pattern')}
        @{name='ls';description='List directory entries alphabetically, including dotfiles; directories have a / suffix. Default 500 entries/50 KiB.';properties=@{path=$string;limit=$positive};required=@()}
    )
    foreach ($spec in $specs) {
        if ($Agent -and $Agent.Permission -eq 'ReadOnly' -and $spec.name -in @('write','edit','powershell')) { continue }
        @{name=$spec.name;description=$spec.description;parameters=@{type='object';properties=$spec.properties;required=$spec.required;additionalProperties=$false}}
    }
}

function Assert-GoSchema($Value,$Schema,[string]$Location='arguments') {
    switch ($Schema.type) {
        'object' {
            if ($Value -isnot [Collections.IDictionary]) { throw "$Location must be an object." }
            foreach ($key in $Schema.required) { if (-not $Value.Contains($key)) { throw "$Location.$key is required." } }
            foreach ($key in $Value.Keys) {
                if (-not $Schema.properties.ContainsKey($key)) { throw "Unknown argument: $Location.$key" }
                Assert-GoSchema $Value[$key] $Schema.properties[$key] "$Location.$key"
            }
        }
        'string' { if ($Value -isnot [string]) { throw "$Location must be a string." } }
        'boolean' { if ($Value -isnot [bool]) { throw "$Location must be boolean." } }
        'array' {
            if ($Value -isnot [array] -and $Value -isnot [Collections.IList]) { throw "$Location must be an array." }
            if ($Value.Count -lt $Schema.minItems) { throw "$Location must contain at least $($Schema.minItems) item(s)." }
            for ($i=0;$i -lt $Value.Count;$i++) { Assert-GoSchema $Value[$i] $Schema.items "$Location[$i]" }
        }
        {$_ -in 'integer','number'} {
            if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -isnot [ValueType]) { throw "$Location must be numeric." }
            $number=[double]$Value
            if (-not [double]::IsFinite($number)) { throw "$Location must be finite." }
            if ($Schema.type -eq 'integer' -and ($number -ne [Math]::Truncate($number) -or $number -gt [int]::MaxValue)) { throw "$Location must be an integer." }
            if ($Schema.ContainsKey('minimum') -and $number -lt $Schema.minimum) { throw "$Location is below minimum $($Schema.minimum)." }
            if ($Schema.ContainsKey('exclusiveMinimum') -and $number -le $Schema.exclusiveMinimum) { throw "$Location must exceed $($Schema.exclusiveMinimum)." }
            if ($Schema.ContainsKey('maximum') -and $number -gt $Schema.maximum) { throw "$Location exceeds maximum $($Schema.maximum)." }
        }
    }
}

function ConvertTo-GoArguments([string]$Name,$Arguments) {
    if ($Arguments -isnot [Collections.IDictionary]) { throw 'Arguments must be an object.' }
    $copy=@{}; foreach ($key in $Arguments.Keys) { $copy[$key]=$Arguments[$key] }
    if ($Name -eq 'edit') {
        if ($copy.ContainsKey('edits')) {
            if ($copy.edits -is [string]) { $copy.edits=ConvertFrom-Json -InputObject $copy.edits -AsHashtable -NoEnumerate }
            if ($copy.edits -is [Collections.IDictionary]) { $copy.edits=@($copy.edits) }
        }
        if ($copy.ContainsKey('oldText') -and $copy.ContainsKey('newText')) {
            $copy.edits=@($(if ($copy.ContainsKey('edits')) {$copy.edits})) + @(@{oldText=$copy.oldText;newText=$copy.newText})
            $copy.Remove('oldText');$copy.Remove('newText')
        }
    }
    if ($Name -eq 'powershell' -and $copy.ContainsKey('timeoutSeconds')) { $copy.timeout=$copy.timeoutSeconds;$copy.Remove('timeoutSeconds') }
    $copy
}

function ConvertTo-GoLF([string]$Text) { $Text.Replace("`r`n","`n").Replace("`r","`n") }
function ConvertTo-GoFuzzy([string]$Text) {
    $normalized=$Text.Normalize([Text.NormalizationForm]::FormKC)
    $normalized=(@($normalized.Split("`n") | ForEach-Object {$_.TrimEnd()})) -join "`n"
    $normalized=[regex]::Replace($normalized,'[\u2018\u2019\u201A\u201B]',"'")
    $normalized=[regex]::Replace($normalized,'[\u201C\u201D\u201E\u201F]','"')
    $normalized=[regex]::Replace($normalized,'[\u2010-\u2015\u2212]','-')
    [regex]::Replace($normalized,'[\u00A0\u2002-\u200A\u202F\u205F\u3000]',' ')
}
function Get-GoOccurrences([string]$Text,[string]$Needle) {
    if ($Needle.Length -eq 0) { return 0 }
    $count=0;$start=0
    while ($start -le $Text.Length-$Needle.Length) {
        $index=$Text.IndexOf($Needle,$start,[StringComparison]::Ordinal)
        if ($index -lt 0) { break };$count++;$start=$index+$Needle.Length
    }
    $count
}

function Get-GoTruncation {
    param([string]$Text,[switch]$Tail,[int]$MaxLines=2000,[int]$MaxBytes=51200)
    $lines=@(if ($Text.Length -eq 0) {@()} else {$Text.Split("`n")})
    if ($Text.EndsWith("`n")) { $lines=@($lines | Select-Object -SkipLast 1) }
    $totalBytes=[Text.Encoding]::UTF8.GetByteCount($Text)
    $result=@{content=$Text;truncated=$false;truncatedBy=$null;totalLines=@($lines).Count;totalBytes=$totalBytes;outputLines=@($lines).Count;outputBytes=$totalBytes;lastLinePartial=$false;firstLineExceedsLimit=$false;maxLines=$MaxLines;maxBytes=$MaxBytes}
    if ($totalBytes -le $MaxBytes -and @($lines).Count -le $MaxLines) { return $result }
    $result.truncated=$true;$result.truncatedBy='lines'
    $selected=[Collections.Generic.List[string]]::new();$bytes=0
    for ($n=0;$n -lt @($lines).Count -and $selected.Count -lt $MaxLines;$n++) {
        $index=if ($Tail) {$lines.Count-1-$n} else {$n}
        $line=$lines[$index];$size=[Text.Encoding]::UTF8.GetByteCount($line)+[int]($selected.Count -gt 0)
        if ($bytes+$size -gt $MaxBytes) {
            $result.truncatedBy='bytes'
            if ($selected.Count -eq 0) {
                if ($Tail) {
                    $raw=[Text.Encoding]::UTF8.GetBytes($line);$start=$raw.Length-$MaxBytes
                    while ($start -lt $raw.Length -and ($raw[$start] -band 0xC0) -eq 0x80) {$start++}
                    $selected.Add([Text.Encoding]::UTF8.GetString($raw,$start,$raw.Length-$start));$result.lastLinePartial=$true
                } else {$result.firstLineExceedsLimit=$true}
            }
            break
        }
        if ($Tail) {$selected.Insert(0,$line)} else {$selected.Add($line)};$bytes+=$size
    }
    $result.content=$selected -join "`n";$result.outputLines=$selected.Count;$result.outputBytes=[Text.Encoding]::UTF8.GetByteCount($result.content)
    $result
}
function New-GoToolResult([string]$Text,[bool]$IsError=$false,$Details=@{},$Content=$null,$StructuredContent=$null) {
    if ($null -eq $Content) {$Content=@(@{type='text';text=$Text})}
    @{text=$Text;isError=$IsError;details=$Details;content=$Content;structuredContent=$StructuredContent}
}
function Complete-GoOutput([string]$Text,$Details=@{},[string[]]$Notices=@()) {
    $truncation=Get-GoTruncation $Text -MaxLines ([int]::MaxValue)
    if ($truncation.truncated) {$Details.truncation=$truncation;$Notices+= '50 KiB limit reached; narrow the query'}
    $output=$truncation.content
    if ($Notices.Count -gt 0) {$output+="`n`n["+($Notices -join '. ')+']'}
    New-GoToolResult $output $false $Details
}

function Write-GoFile([string]$Path,[byte[]]$Bytes) {
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temp=$Path+'.'+[guid]::NewGuid().ToString()+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temp,$Bytes)
        if ([IO.File]::Exists($Path)) {
            # Keep permission bits when atomic replacement is supported by this runtime.
            if (-not $IsWindows -and [Environment]::Version.Major -ge 7) {[IO.File]::SetUnixFileMode($temp,[IO.File]::GetUnixFileMode($Path))}
            [IO.File]::SetAttributes($temp,[IO.File]::GetAttributes($Path))
        }
        [IO.File]::Move($temp,$Path,$true)
    } finally {if ([IO.File]::Exists($temp)) {[IO.File]::Delete($temp)}}
}
function Get-GoMutationMutex([string]$Path) {
    $key=if ($IsWindows) {$Path.ToUpperInvariant()} else {$Path}
    $sha=[Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))
    [Threading.Mutex]::new($false,'PSGoAgent-'+[Convert]::ToHexString($sha))
}

function Get-GoDiff([string]$Path,[string]$Before,[string]$After) {
    # Bounded LCS over changed line blocks; large blocks use a valid full-block replacement.
    $old=@([regex]::Matches($Before,'[^\n]*\n|[^\n]+') | ForEach-Object Value)
    $new=@([regex]::Matches($After,'[^\n]*\n|[^\n]+') | ForEach-Object Value)
    $prefix=0
    while ($prefix -lt [Math]::Min($old.Count,$new.Count) -and $old[$prefix] -ceq $new[$prefix]) {$prefix++}
    $suffix=0
    while ($suffix -lt [Math]::Min($old.Count,$new.Count)-$prefix -and $old[$old.Count-1-$suffix] -ceq $new[$new.Count-1-$suffix]) {$suffix++}
    $m=$old.Count-$prefix-$suffix;$n=$new.Count-$prefix-$suffix
    $ops=[Collections.Generic.List[object]]::new()
    for ($i=0;$i -lt $prefix;$i++) {$ops.Add(@{kind=' ';text=$old[$i]})}
    if ([long]$m*$n -le 250000) {
        $matrix=[int[,]]::new($m+1,$n+1)
        for ($i=$m-1;$i -ge 0;$i--) {for ($j=$n-1;$j -ge 0;$j--) {
            $matrix[$i,$j]=if ($old[$prefix+$i] -ceq $new[$prefix+$j]) {1+$matrix[($i+1),($j+1)]} else {[Math]::Max($matrix[($i+1),$j],$matrix[$i,($j+1)])}
        }}
        $i=0;$j=0
        while ($i -lt $m -or $j -lt $n) {
            if ($i -lt $m -and $j -lt $n -and $old[$prefix+$i] -ceq $new[$prefix+$j]) {$ops.Add(@{kind=' ';text=$old[$prefix+$i]});$i++;$j++}
            elseif ($i -lt $m -and ($j -eq $n -or $matrix[($i+1),$j] -ge $matrix[$i,($j+1)])) {$ops.Add(@{kind='-';text=$old[$prefix+$i]});$i++}
            else {$ops.Add(@{kind='+';text=$new[$prefix+$j]});$j++}
        }
    } else {
        for ($i=$prefix;$i -lt $old.Count-$suffix;$i++) {$ops.Add(@{kind='-';text=$old[$i]})}
        for ($i=$prefix;$i -lt $new.Count-$suffix;$i++) {$ops.Add(@{kind='+';text=$new[$i]})}
    }
    for ($i=$old.Count-$suffix;$i -lt $old.Count;$i++) {$ops.Add(@{kind=' ';text=$old[$i]})}
    $oldLine=1;$newLine=1;$first=$null;$hunks=[Collections.Generic.List[object]]::new()
    for ($i=0;$i -lt $ops.Count;$i++) {
        $op=$ops[$i];$op.oldLine=$oldLine;$op.newLine=$newLine
        if ($op.kind -ne '+') {$oldLine++};if ($op.kind -ne '-') {$newLine++}
        if ($op.kind -ne ' ') {
            if ($null -eq $first) {$first=$op.newLine}
            $start=[Math]::Max(0,$i-4);$end=[Math]::Min($ops.Count,$i+5)
            if ($hunks.Count -gt 0 -and $start -le $hunks[$hunks.Count-1].end) {$hunks[$hunks.Count-1].end=$end}
            else {$hunks.Add(@{start=$start;end=$end})}
        }
    }
    $patch=[Collections.Generic.List[string]]::new();$display=[Collections.Generic.List[string]]::new()
    $safePath=$Path.Replace("`r",'').Replace("`n",'')
    $patch.Add('--- '+$safePath);$patch.Add('+++ '+$safePath)
    foreach ($hunk in $hunks) {
        $part=@($ops.GetRange($hunk.start,$hunk.end-$hunk.start))
        $oldCount=@($part | Where-Object kind -NE '+').Count;$newCount=@($part | Where-Object kind -NE '-').Count
        $oldStart=$part[0].oldLine-[int]($oldCount -eq 0);$newStart=$part[0].newLine-[int]($newCount -eq 0)
        $patch.Add("@@ -$oldStart,$oldCount +$newStart,$newCount @@")
        if ($display.Count -gt 0) {$display.Add(' ...')}
        foreach ($op in $part) {
            $line=$op.text.TrimEnd([char]10)
            $patch.Add($op.kind+$line)
            if (-not $op.text.EndsWith("`n")) {$patch.Add('\ No newline at end of file')}
            $number=if ($op.kind -eq '+') {$op.newLine} else {$op.oldLine}
            $display.Add(('{0}{1} {2}' -f $op.kind,$number,$line))
        }
    }
    @{diff=($display -join "`n");patch=(($patch -join "`n")+"`n");firstChangedLine=$first}
}

function Invoke-GoEdit([string]$Path,$Edits,[Threading.CancellationToken]$CancellationToken) {
    $raw=[IO.File]::ReadAllBytes($Path)
    $bom=$raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191
    $content=[Text.UTF8Encoding]::new($false,$true).GetString($raw,$(if ($bom) {3} else {0}),$raw.Length-$(if ($bom) {3} else {0}))
    $ending=if ($content.Contains("`n") -and $content.IndexOf("`r`n") -ge 0 -and $content.IndexOf("`r`n") -lt $content.IndexOf("`n")) {"`r`n"} else {"`n"}
    $original=ConvertTo-GoLF $content
    $editsNormalized=@(foreach ($edit in $Edits) {
        $old=ConvertTo-GoLF $edit.oldText
        if ($old.Length -eq 0) {throw 'oldText must not be empty.'}
        @{oldText=$old;newText=(ConvertTo-GoLF $edit.newText)}
    })
    $fuzzy=$false
    foreach ($edit in $editsNormalized) {if ($original.IndexOf($edit.oldText,[StringComparison]::Ordinal) -lt 0 -and (ConvertTo-GoFuzzy $original).Contains((ConvertTo-GoFuzzy $edit.oldText))) {$fuzzy=$true}}
    $base=if ($fuzzy) {ConvertTo-GoFuzzy $original} else {$original}
    $matches=@(foreach ($edit in $editsNormalized) {
        $CancellationToken.ThrowIfCancellationRequested()
        $needle=$edit.oldText;$index=$base.IndexOf($needle,[StringComparison]::Ordinal)
        if ($index -lt 0) {$needle=ConvertTo-GoFuzzy $needle;$index=$base.IndexOf($needle,[StringComparison]::Ordinal)}
        if ($needle.Length -eq 0 -or $index -lt 0) {throw 'oldText not found; read the file again.'}
        if ((Get-GoOccurrences (ConvertTo-GoFuzzy $base) (ConvertTo-GoFuzzy $edit.oldText)) -gt 1) {throw 'oldText is ambiguous; provide more context.'}
        @{index=$index;length=$needle.Length;newText=$edit.newText}
    }) | Sort-Object index
    $matches=@($matches)
    for ($i=1;$i -lt $matches.Count;$i++) {if ($matches[$i].index -lt $matches[$i-1].index+$matches[$i-1].length) {throw 'Edits overlap; merge them or target disjoint regions.'}}
    if ($fuzzy) {
        # Rewrite only touched line groups; unrelated Unicode/trailing whitespace remains intact.
        $originalLines=@([regex]::Matches($original,'[^\n]*\n|[^\n]+') | ForEach-Object Value)
        $baseLines=@([regex]::Matches($base,'[^\n]*\n|[^\n]+') | ForEach-Object Value)
        if ($originalLines.Count -ne $baseLines.Count) {throw 'Fuzzy normalization changed line count.'}
        $starts=[Collections.Generic.List[int]]::new();$offset=0
        foreach ($line in $baseLines) {$starts.Add($offset);$offset+=$line.Length}
        $groups=[Collections.Generic.List[object]]::new()
        foreach ($match in $matches) {
            $startLine=0;while ($startLine+1 -lt $starts.Count -and $starts[$startLine+1] -le $match.index) {$startLine++}
            $endLine=$startLine;while ($endLine+1 -lt $starts.Count -and $starts[$endLine]+$baseLines[$endLine].Length -lt $match.index+$match.length) {$endLine++}
            if ($groups.Count -gt 0 -and $startLine -le $groups[$groups.Count-1].endLine) {$groups[$groups.Count-1].endLine=[Math]::Max($endLine,$groups[$groups.Count-1].endLine);$groups[$groups.Count-1].matches.Add($match)}
            else {$list=[Collections.Generic.List[object]]::new();$list.Add($match);$groups.Add(@{startLine=$startLine;endLine=$endLine;matches=$list})}
        }
        $builder=[Text.StringBuilder]::new();$cursor=0
        foreach ($group in $groups) {
            for (;$cursor -lt $group.startLine;$cursor++) {$null=$builder.Append($originalLines[$cursor])}
            $offset=$starts[$group.startLine];$block=$base.Substring($offset,$starts[$group.endLine]+$baseLines[$group.endLine].Length-$offset)
            for ($i=$group.matches.Count-1;$i -ge 0;$i--) {$match=$group.matches[$i];$at=$match.index-$offset;$block=$block.Substring(0,$at)+$match.newText+$block.Substring($at+$match.length)}
            $null=$builder.Append($block);$cursor=$group.endLine+1
        }
        for (;$cursor -lt $originalLines.Count;$cursor++) {$null=$builder.Append($originalLines[$cursor])}
        $updated=$builder.ToString()
    } else {
        $updated=$base
        for ($i=$matches.Count-1;$i -ge 0;$i--) {$match=$matches[$i];$updated=$updated.Substring(0,$match.index)+$match.newText+$updated.Substring($match.index+$match.length)}
    }
    if ($updated -ceq $original) {throw 'No changes made: replacement produced identical content.'}
    $details=Get-GoDiff $Path $original $updated
    $final=if ($ending -eq "`r`n") {$updated.Replace("`n","`r`n")} else {$updated}
    $encoding=[Text.UTF8Encoding]::new($bom)
    $bytes=$encoding.GetPreamble()+$encoding.GetBytes($final)
    $CancellationToken.ThrowIfCancellationRequested()
    Write-GoFile $Path $bytes
    Complete-GoOutput "Successfully replaced $($Edits.Count) block(s) in $Path.`n$($details.diff)" $details
}

function Get-GoGlobRegex([string]$Pattern,[switch]$Basename) {
    $pattern=$Pattern.Replace('\','/')
    $builder=[Text.StringBuilder]::new();$null=$builder.Append('^');$i=0;$braceDepth=0
    while ($i -lt $pattern.Length) {
        $c=$pattern[$i]
        switch ($c) {
            '*' {
                if ($i+1 -lt $pattern.Length -and $pattern[$i+1] -eq '*') {
                    $i++
                    if ($i+1 -lt $pattern.Length -and $pattern[$i+1] -eq '/') {$i++;$null=$builder.Append('(?:.*/)?')}
                    else {$null=$builder.Append('.*')}
                } else {$null=$builder.Append('[^/]*')}
            }
            '?' {$null=$builder.Append('[^/]')}
            '[' {
                $end=$pattern.IndexOf(']',$i+1)
                if ($end -gt $i+1) {
                    $set=$pattern.Substring($i+1,$end-$i-1)
                    if ($set.StartsWith('!')) {$set='^'+$set.Substring(1)}
                    $null=$builder.Append('['+$set+']');$i=$end
                } else {$null=$builder.Append('\[')}
            }
            '{' {$braceDepth++;$null=$builder.Append('(?:')}
            '}' {if ($braceDepth -gt 0) {$braceDepth--;$null=$builder.Append(')')} else {$null=$builder.Append('\}')}}
            ',' {$null=$builder.Append($(if ($braceDepth -gt 0) {'|'} else {','}))}
            default {$null=$builder.Append([regex]::Escape([string]$c))}
        }
        $i++
    }
    if ($braceDepth -gt 0) {throw 'Unclosed brace in glob pattern.'}
    $null=$builder.Append('$')
    $options=if ($IsWindows) {[Text.RegularExpressions.RegexOptions]::IgnoreCase} else {[Text.RegularExpressions.RegexOptions]::None}
    [regex]::new($builder.ToString(),$options,[TimeSpan]::FromSeconds(2))
}
function Get-GoIgnoreRules([string]$Directory) {
    foreach ($filename in @('.gitignore','.ignore')) {
        $file=Join-Path $Directory $filename
        if (-not [IO.File]::Exists($file)) {continue}
        foreach ($raw in [IO.File]::ReadLines($file)) {
            $line=$raw.TrimEnd()
            if (-not $line -or $line.StartsWith('#')) {continue}
            $negative=$line.StartsWith('!');if ($negative) {$line=$line.Substring(1)}
            if ($line.StartsWith('\#') -or $line.StartsWith('\!')) {$line=$line.Substring(1)}
            $directoryOnly=$line.EndsWith('/');$line=$line.TrimEnd('/')
            $anchored=$line.StartsWith('/');$line=$line.TrimStart('/')
            if (-not $line) {continue}
            @{base=$Directory;negate=$negative;directoryOnly=$directoryOnly;basename=(-not $anchored -and -not $line.Contains('/'));regex=(Get-GoGlobRegex $line)}
        }
    }
}
function Test-GoIgnored([string]$Path,[bool]$IsDirectory,$Rules) {
    $ignored=$false
    foreach ($rule in $Rules) {
        $relative=[IO.Path]::GetRelativePath($rule.base,$Path).Replace([IO.Path]::DirectorySeparatorChar,'/')
        if ($relative -eq '..' -or $relative.StartsWith('../')) {continue}
        if ($rule.directoryOnly -and -not $IsDirectory) {continue}
        $candidate=if ($rule.basename) {[IO.Path]::GetFileName($Path)} else {$relative}
        if ($rule.regex.IsMatch($candidate)) {$ignored=-not $rule.negate}
    }
    $ignored
}
function Get-GoSearchEntries($Agent,[string]$Root,[Threading.CancellationToken]$CancellationToken) {
    $inherited=@();$parents=[Collections.Generic.List[string]]::new();$cursor=$Root
    while ($cursor -and $cursor.StartsWith($Agent.Workspace,[StringComparison]::Ordinal)) {
        $parents.Insert(0,$cursor)
        if ($cursor -eq $Agent.Workspace -or (Test-Path -LiteralPath (Join-Path $cursor '.git'))) {break}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    foreach ($parent in $parents) {$inherited+=@(Get-GoIgnoreRules $parent)}
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{path=$Root;rules=$inherited})
    while ($stack.Count -gt 0) {
        $CancellationToken.ThrowIfCancellationRequested();$current=$stack.Pop()
        foreach ($entry in Get-ChildItem -LiteralPath $current.path -Force | Sort-Object Name) {
            $CancellationToken.ThrowIfCancellationRequested()
            if ($entry.Name -in @('.git','.power-agent') -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {continue}
            if (Test-GoIgnored $entry.FullName $entry.PSIsContainer $current.rules) {continue}
            $entry
            if ($entry.PSIsContainer) {
                $rules=if (Test-Path -LiteralPath (Join-Path $entry.FullName '.git')) {@()} else {@($current.rules)}
                $rules+=@(Get-GoIgnoreRules $entry.FullName)
                $stack.Push(@{path=$entry.FullName;rules=$rules})
            }
        }
    }
}

function Invoke-GoRead([string]$Path,$Arguments) {
    $file=Get-Item -LiteralPath $Path
    if ($file.PSIsContainer) {throw 'read requires a file.'}
    $stream=[IO.File]::OpenRead($Path)
    try {$header=[byte[]]::new(12);$length=$stream.Read($header,0,12)} finally {$stream.Dispose()}
    $mime=$null
    if ($length -ge 8 -and [Convert]::ToHexString($header,0,8) -eq '89504E470D0A1A0A') {$mime='image/png'}
    elseif ($length -ge 3 -and $header[0] -eq 255 -and $header[1] -eq 216 -and $header[2] -eq 255) {$mime='image/jpeg'}
    elseif ($length -ge 6 -and [Text.Encoding]::ASCII.GetString($header,0,6) -in @('GIF87a','GIF89a')) {$mime='image/gif'}
    elseif ($length -ge 12 -and [Text.Encoding]::ASCII.GetString($header,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($header,8,4) -eq 'WEBP') {$mime='image/webp'}
    elseif ($length -ge 2 -and $header[0] -eq 66 -and $header[1] -eq 77) {throw 'BMP conversion requires an image codec; use PNG/JPEG/GIF/WebP.'}
    if ($mime) {
        if ($file.Length -gt 5MB) {throw 'Image exceeds 5 MiB; resize externally before reading.'}
        $data=[Convert]::ToBase64String([IO.File]::ReadAllBytes($Path));$text="Read image file [$mime]"
        return New-GoToolResult $text $false @{} @(@{type='text';text=$text},@{type='image';data=$data;mimeType=$mime}) @{type='image';data=$data;mimeType=$mime;note=$text}
    }
    if ($length -gt 0 -and $header[0..($length-1)] -contains 0) {throw 'Binary file cannot be read as UTF-8 text.'}
    $offset=if ($Arguments.ContainsKey('offset')) {$Arguments.offset} else {1}
    $limit=if ($Arguments.ContainsKey('limit')) {$Arguments.limit} else {[int]::MaxValue}
    $lines=[IO.File]::ReadAllText($Path).Split("`n")
    if ($offset -gt $lines.Count) {throw "Offset $offset exceeds end of file ($($lines.Count) lines)."}
    $end=[int][Math]::Min([long]$lines.Count,[long]$offset+$limit-1)
    $selected=($lines[($offset-1)..($end-1)] -join "`n")
    $truncation=Get-GoTruncation $selected
    $text=$truncation.content
    if ($truncation.firstLineExceedsLimit) {$text="[Line $offset exceeds 50 KiB. Use powershell to inspect a bounded portion of the line.]"}
    elseif ($truncation.truncated -or $end -lt $lines.Count) {
        $next=$offset+$truncation.outputLines
        $text+="`n`n[Showing lines $offset-$($next-1) of $($lines.Count). Use offset=$next to continue.]"
    }
    New-GoToolResult $text $false @{truncation=$truncation} $null $text
}

function Invoke-GoSearch($Agent,[string]$Name,[string]$Path,$Arguments,[Threading.CancellationToken]$CancellationToken) {
    $details=@{};$notices=@();$rows=[Collections.Generic.List[string]]::new()
    $limit=if ($Arguments.ContainsKey('limit')) {$Arguments.limit} elseif ($Name -eq 'grep') {100} elseif ($Name -eq 'find') {1000} else {500}
    if ($Name -eq 'ls') {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {throw "Not a directory: $Path"}
        $entries=@(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)
        foreach ($entry in $entries | Select-Object -First $limit) {$rows.Add($entry.Name+$(if ($entry.PSIsContainer) {'/'} else {''}))}
        if ($entries.Count -gt $limit) {$details.entryLimitReached=$limit;$notices+="$limit entries limit reached. Use limit=$($limit*2) for more"}
        if ($rows.Count -eq 0) {return New-GoToolResult '(empty directory)'}
        return Complete-GoOutput ($rows -join "`n") $details $notices
    }
    $isDirectory=Test-Path -LiteralPath $Path -PathType Container
    if (-not (Test-Path -LiteralPath $Path)) {throw "Path not found: $Path"}
    if ($Name -eq 'find' -and -not $isDirectory) {throw 'find requires a directory.'}
    $glob=$null
    if ($Name -eq 'find') {$pattern=$Arguments.pattern;$glob=Get-GoGlobRegex $pattern}
    elseif ($Arguments.ContainsKey('glob')) {$pattern=$Arguments.glob;$glob=Get-GoGlobRegex $pattern}
    if ($Name -eq 'grep') {
        $searchPattern=if ($Arguments.ContainsKey('literal') -and $Arguments.literal) {[regex]::Escape($Arguments.pattern)} else {$Arguments.pattern}
        $options=if ($Arguments.ContainsKey('ignoreCase') -and $Arguments.ignoreCase) {[Text.RegularExpressions.RegexOptions]::IgnoreCase} else {[Text.RegularExpressions.RegexOptions]::None}
        $regex=[regex]::new($searchPattern,$options,[TimeSpan]::FromSeconds(2))
        $context=if ($Arguments.ContainsKey('context')) {$Arguments.context} else {0}
    }
    $state=@{matches=0;bytes=0;stop=$false}
    # Pipeline traversal stops as soon as result/byte limits are reached.
    try {
        & {if ($isDirectory) {Get-GoSearchEntries $Agent $Path $CancellationToken} else {Get-Item -LiteralPath $Path}} | ForEach-Object {
            $entry=$_;$CancellationToken.ThrowIfCancellationRequested()
            $relative=if ($isDirectory) {[IO.Path]::GetRelativePath($Path,$entry.FullName).Replace([IO.Path]::DirectorySeparatorChar,'/')} else {$entry.Name}
            $candidate=if ($glob -and -not $pattern.Contains('/')) {$entry.Name} else {$relative}
            if ($glob -and -not $glob.IsMatch($candidate)) {return}
            if ($Name -eq 'find') {
                $rows.Add($relative+$(if ($entry.PSIsContainer) {'/'} else {''}));$state.matches++;$state.bytes+=[Text.Encoding]::UTF8.GetByteCount($relative)+1
            } elseif (-not $entry.PSIsContainer) {
                # A NUL marks binary data like ripgrep. Skip binary files even if a later line matches.
                $stream=[IO.File]::OpenRead($entry.FullName)
                try {$buffer=[byte[]]::new([int][Math]::Min(8192,$stream.Length));$null=$stream.Read($buffer,0,$buffer.Length)} finally {$stream.Dispose()}
                if ($buffer -contains 0) {return}
                $lines=@([IO.File]::ReadLines($entry.FullName))
                for ($i=0;$i -lt $lines.Count;$i++) {
                    $CancellationToken.ThrowIfCancellationRequested()
                    if (-not $regex.IsMatch($lines[$i])) {continue}
                    $state.matches++
                    $start=[Math]::Max(0,[long]$i-$context);$end=[Math]::Min($lines.Count-1,[long]$i+$context)
                    for ($j=$start;$j -le $end;$j++) {
                        $line=$lines[$j].TrimEnd([char]13)
                        if ($line.Length -gt 500) {$line=$line.Substring(0,500)+'... [truncated]';$details.linesTruncated=$true}
                        $row=if ($j -eq $i) {"${relative}:$($j+1): $line"} else {"${relative}-$($j+1)- $line"}
                        $rows.Add($row);$state.bytes+=[Text.Encoding]::UTF8.GetByteCount($row)+1
                        if ($state.bytes -gt 51200) {break}
                    }
                    if ($state.matches -ge $limit -or $state.bytes -gt 51200) {break}
                }
            }
            if ($state.matches -ge $limit -or $state.bytes -gt 51200) {throw [OperationCanceledException]::new('GoSearchLimit')}
        }
    } catch {if ($_.Exception.Message -ne 'GoSearchLimit') {throw}}
    if ($state.matches -ge $limit) {
        $key=if ($Name -eq 'grep') {'matchLimitReached'} else {'resultLimitReached'};$details[$key]=$limit
        $notices+="$limit results limit reached. Use limit=$($limit*2) for more, or refine pattern"
    }
    if ($details.ContainsKey('linesTruncated')) {$notices+='Some lines truncated to 500 characters; use read for full lines'}
    if ($rows.Count -eq 0) {return New-GoToolResult $(if ($Name -eq 'grep') {'No matches found'} else {'No files found matching pattern'})}
    Complete-GoOutput ($rows -join "`n") $details $notices
}

function Invoke-GoPowerShell($Agent,$Arguments,[Threading.CancellationToken]$CancellationToken,[scriptblock]$OnUpdate) {
    $directory=Resolve-GoPath $Agent '.power-agent/output'
    $null=[IO.Directory]::CreateDirectory($directory)
    $id=[guid]::NewGuid().ToString();$outputPath=Join-Path $directory "$id.log";$errorPath=Join-Path $directory "$id.err"
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})
    $start.WorkingDirectory=$Agent.Workspace;$start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach ($argument in @('-NoProfile','-NonInteractive','-EncodedCommand')) {$start.ArgumentList.Add($argument)}
    # Merge PowerShell streams in the child. Native stderr is captured without making it terminating.
    $command='[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference="Stop"; $PSNativeCommandUseErrorActionPreference=$false; try { & { '+$Arguments.command+' } *>&1 | Out-String -Stream | ForEach-Object { [Console]::WriteLine($_) }; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }; if (-not $?) { exit 1 } } catch { [Console]::WriteLine($_.ToString()); exit 1 }'
    $start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    $null=$start.Environment.Remove('OPENCODE_API_KEY')
    $start.Environment['PI_SESSION_ID']=$Agent.Id;$start.Environment['PI_MODEL_ID']=$Agent.Model;$start.Environment['PI_MODEL_PROVIDER']='opencode-go'
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $output=[IO.FileStream]::new($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1)
    $errors=[IO.FileStream]::new($errorPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1)
    $timer=[Diagnostics.Stopwatch]::StartNew();$status=$null;$reader=$null;$started=$false
    try {
        $CancellationToken.ThrowIfCancellationRequested();$null=$process.Start();$started=$true
        $stdout=$process.StandardOutput.BaseStream.CopyToAsync($output);$stderr=$process.StandardError.BaseStream.CopyToAsync($errors)
        if ($OnUpdate) {$reader=[IO.StreamReader]::new([IO.FileStream]::new($outputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite),[Text.Encoding]::UTF8)}
        while (-not $process.WaitForExit(100)) {
            if ($reader) {
                $buffer=[char[]]::new(8192)
                while (($count=$reader.Read($buffer,0,$buffer.Length)) -gt 0) {$null=& $OnUpdate @{type='tool_update';name='powershell';text=[string]::new($buffer,0,$count)}}
            }
            if ($CancellationToken.IsCancellationRequested) {$status='Command aborted';$process.Kill($true);break}
            if ($Arguments.ContainsKey('timeout') -and $timer.Elapsed.TotalSeconds -ge $Arguments.timeout) {$status="Command timed out after $($Arguments.timeout) seconds";$process.Kill($true);break}
        }
        $process.WaitForExit();$null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult();$output.Dispose();$errors.Dispose()
        if ($reader) {$buffer=[char[]]::new(8192);while (($count=$reader.Read($buffer,0,$buffer.Length)) -gt 0) {$null=& $OnUpdate @{type='tool_update';name='powershell';text=[string]::new($buffer,0,$count)}};$reader.Dispose();$reader=$null}
        # Unexpected runtime stderr is appended; normal command streams were merged in the child.
        if ((Get-Item -LiteralPath $errorPath).Length -gt 0) {
            $destination=[IO.File]::Open($outputPath,[IO.FileMode]::Append,[IO.FileAccess]::Write)
            $source=[IO.File]::OpenRead($errorPath)
            try {$source.CopyTo($destination)} finally {$source.Dispose();$destination.Dispose()}
        }
        $file=[IO.File]::OpenRead($outputPath)
        try {
            # Keep bounded memory even when command output is very large or has no newlines.
            $startAt=[Math]::Max(0,$file.Length-51204);$null=$file.Seek($startAt,[IO.SeekOrigin]::Begin)
            $bytes=[byte[]]::new([int]($file.Length-$startAt));$null=$file.Read($bytes,0,$bytes.Length)
            $at=0;while ($at -lt $bytes.Length -and ($bytes[$at] -band 0xC0) -eq 0x80) {$at++}
            $tail=[Text.Encoding]::UTF8.GetString($bytes,$at,$bytes.Length-$at)
        } finally {$file.Dispose()}
        $truncation=Get-GoTruncation $tail -Tail
        $length=(Get-Item -LiteralPath $outputPath).Length
        $truncated=$truncation.truncated -or $length -gt 51200
        $text=$truncation.content
        if (-not $text) {$text='(no output)'}
        $details=@{exitCode=$process.ExitCode;wallTimeSeconds=[Math]::Round($timer.Elapsed.TotalSeconds,3)}
        if ($truncated -or $status) {$details.fullOutputPath=$outputPath;$details.truncation=$truncation;$text+="`n`n[Showing last 2000 lines / 50 KiB. Full output: $outputPath]"}
        else {[IO.File]::Delete($outputPath)}
        $text+="`nexit_code: $($process.ExitCode)"
        if ($status) {$text+="`n$status"}
        New-GoToolResult $text ($null -ne $status -or $process.ExitCode -ne 0) $details $null @{output=$truncation.content;truncated=$truncated;full_output_path=$(if ($truncated -or $status) {$outputPath} else {$null});exit_code=$process.ExitCode;wall_time_seconds=$details.wallTimeSeconds}
    } finally {
        if ($started -and -not $process.HasExited) {$process.Kill($true);$process.WaitForExit()}
        if ($reader) {$reader.Dispose()};$output.Dispose();$errors.Dispose();$process.Dispose()
        if ([IO.File]::Exists($errorPath)) {[IO.File]::Delete($errorPath)}
    }
}

function Invoke-GoTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Agent,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Arguments,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,[scriptblock]$OnUpdate)
    $mutex=$null;$locked=$false
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        $Name=switch ($Name) {'shell' {'powershell'} 'list' {'ls'} default {$Name}}
        $argumentsNormalized=ConvertTo-GoArguments $Name $Arguments
        $spec=@(Get-GoTools | Where-Object name -EQ $Name)
        if ($spec.Count -ne 1) {throw "Unknown tool: $Name"}
        Assert-GoSchema $argumentsNormalized $spec[0].parameters
        $path=if ($Name -ne 'powershell') {Resolve-GoPath $Agent $(if ($argumentsNormalized.ContainsKey('path')) {$argumentsNormalized.path} else {'.'})} else {$null}
        if ($Name -in @('write','edit','powershell')) {
            if ($Agent.Permission -eq 'ReadOnly') {throw 'Action denied by ReadOnly permission.'}
            if ($Agent.Permission -eq 'Ask') {
                $allowed=if ($Agent.Approve) {& $Agent.Approve $Name $argumentsNormalized} else {
                    Write-Host ("Tool: {0}`n{1}" -f $Name,($argumentsNormalized | ConvertTo-Json -Depth 20))
                    (Read-Host 'Allow this action? [y/N]') -ceq 'y'
                }
                if ($allowed -ne $true) {throw 'Action denied by user.'}
            }
            if ($Name -ne 'powershell') {
                $mutex=Get-GoMutationMutex $path
                while (-not $locked) {
                    $CancellationToken.ThrowIfCancellationRequested()
                    try {$locked=$mutex.WaitOne(100)} catch [Threading.AbandonedMutexException] {$locked=$true}
                }
                $path=Resolve-GoPath $Agent $argumentsNormalized.path
            }
        }
        $CancellationToken.ThrowIfCancellationRequested()
        switch ($Name) {
            'read' {Invoke-GoRead $path $argumentsNormalized}
            'write' {Write-GoFile $path ([Text.Encoding]::UTF8.GetBytes($argumentsNormalized.content));New-GoToolResult "Wrote $([Text.Encoding]::UTF8.GetByteCount($argumentsNormalized.content)) bytes to $($argumentsNormalized.path)."}
            'edit' {Invoke-GoEdit $path $argumentsNormalized.edits $CancellationToken}
            'powershell' {Invoke-GoPowerShell $Agent $argumentsNormalized $CancellationToken $OnUpdate}
            default {Invoke-GoSearch $Agent $Name $path $argumentsNormalized $CancellationToken}
        }
    } catch {New-GoToolResult $_.Exception.Message $true}
    finally {if ($locked) {$mutex.ReleaseMutex()};if ($mutex) {$mutex.Dispose()}}
}

function Get-GoResultImages($Agent,$Message) {
    if ($Agent.EnableImages -and $Message.ContainsKey('content')) { $Message.content | Where-Object type -EQ 'image' }
}
function Get-GoResultText($Agent,$Message) {
    $text=$Message.text
    if (-not $Agent.EnableImages -and $Message.ContainsKey('content') -and @($Message.content | Where-Object type -EQ 'image').Count -gt 0) {
        $text+="`n[Image omitted: enable image input only for a vision-capable model with -EnableImages.]"
    }
    $text
}
