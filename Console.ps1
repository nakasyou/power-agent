function New-GoConsoleRenderer {
    param([switch]$HideReasoning,[switch]$CompactReasoning,[switch]$Plain,[hashtable]$State)
    if (-not $State) {$State=@{}}
    $state=$State
    $state.section=$null;$state.tools=@{};$state.events=[Collections.Generic.List[object]]::new()
    $state.expanded=$false;$state.replaying=$false;$state.reasoning='';$state.reasonTop=0;$state.reasonRows=0
    $state.native=[bool]($CompactReasoning -and -not $Plain -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
    $compact=[bool]$CompactReasoning
    $hide=[bool]$HideReasoning
    $callback={
        param($event)
        if ($state.native -and -not $state.replaying -and [Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            if (($key.Key -eq 'Escape' -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))) -and $state.ContainsKey('cancellation') -and $state.cancellation) {$state.cancellation.Cancel()}
            if ($key.Key -eq 'O' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {Switch-GoReasoningView $state}
        }
        if ($event.type -eq 'ui_tick') {return}
        if (-not $state.replaying) {$state.events.Add($event)}
        if ($compact -and $state.section -eq 'reasoning' -and $event.type -in @('text_delta','assistant_end','tool_start','agent_error','retry')) {
            if (-not $state.native -or $state.replaying) {Write-GoReasoningSummary $state}
            elseif ($state.expanded) {Write-Host ''}
            $state.section=$null
        }
        switch ($event.type) {
            'user' {if ($state.replaying -or -not $event.ContainsKey('silent') -or -not $event.silent) {Write-Host "❯ $($event.text)" -ForegroundColor Green}}
            'assistant_start' {$state.section=$null;$state.reasoning=''}
            {$_ -in @('reasoning_delta','text_delta')} {
                if ($event.type -eq 'reasoning_delta' -and $hide) {return}
                if ($event.type -eq 'reasoning_delta' -and $compact) {
                    if ($state.section -ne 'reasoning') {
                        if ($state.section) {Write-Host ''}
                        $state.section='reasoning';$state.reasoning=''
                        if ($state.native -and -not $state.replaying) {$state.reasonTop=[Console]::CursorTop;$state.reasonRows=0}
                    }
                    $state.reasoning+=$event.delta
                    if ($state.native -and -not $state.replaying) {
                        if ($state.expanded) {
                            if ($state.reasonRows -eq 0) {Write-Host '[reasoning · Ctrl+O 折りたたむ]' -ForegroundColor DarkGray;$state.reasonRows=1}
                            Write-Host $event.delta -NoNewline -ForegroundColor DarkGray
                        } else {Write-GoReasoningLive $state}
                    }
                    return
                }
                $section=if ($event.type -eq 'reasoning_delta') {'reasoning'} else {'assistant'}
                if ($state.section -ne $section) {
                    if ($state.section) {Write-Host ''}
                    Write-Host "[$section]" -ForegroundColor $(if ($section -eq 'reasoning') {'DarkGray'} else {'Cyan'})
                    $state.section=$section
                }
                Write-Host $event.delta -NoNewline -ForegroundColor $(if ($section -eq 'reasoning') {'DarkGray'} else {'White'})
            }
            'assistant_end' {if ($state.section) {Write-Host ''};$state.section=$null}
            'tool_start' {
                if ($state.section) {Write-Host ''; $state.section=$null}
                $state.tools[$event.callId]=$false
                Write-Host "[tool: $($event.name)]" -ForegroundColor Yellow
            }
            'tool_output_delta' {
                $state.tools[$event.callId]=$true
                Write-Host $event.delta -NoNewline
            }
            'tool_end' {
                if ($state.tools.ContainsKey($event.callId) -and $state.tools[$event.callId]) {
                    Write-Host ''
                    if ($event.details -and $event.details.ContainsKey('exitCode')) {Write-Host "exit_code: $($event.details.exitCode)"}
                    if ($event.details -and $event.details.ContainsKey('fullOutputPath')) {Write-Host "Full output: $($event.details.fullOutputPath)"}
                    if ($event.isError) {Write-Host '[tool failed or interrupted]' -ForegroundColor Red}
                    if ($event.details -and $event.details.ContainsKey('status')) {Write-Host $event.details.status -ForegroundColor Red}
                } else {Write-Host $event.text -ForegroundColor $(if ($event.isError) {'Red'} else {'Gray'})}
                $state.tools.Remove($event.callId)
            }
            'retry' {
                if ($state.section) {Write-Host ''; $state.section=$null}
                Write-Host "↻ 自動再送 $($event.attempt)/$($event.maxRetries) · $($event.delaySeconds)秒後 · HTTP $($event.status)" -ForegroundColor Yellow
            }
            'agent_error' {if ($state.section) {Write-Host ''; $state.section=$null}}
        }
    }.GetNewClosure()
    $state.callback=$callback
    $callback
}

function Get-GoReasoningTail {
    param([string]$Text,[int]$Width=80)
    $lines=[Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -replace "`r",'' -split "`n")) {
        if (-not $line.Length) {$lines.Add('');continue}
        # Conservative width accommodates double-width Japanese characters.
        $length=[Math]::Max(5,[int]($Width/2)-2)
        for ($i=0;$i -lt $line.Length;$i+=$length) {$lines.Add($line.Substring($i,[Math]::Min($length,$line.Length-$i)))}
    }
    @($lines | Select-Object -Last 3)
}
function Write-GoReasoningSummary {
    param([hashtable]$State)
    if (-not $State.reasoning) {return}
    if ($State.expanded) {
        Write-Host '[reasoning · Ctrl+O 折りたたむ]' -ForegroundColor DarkGray
        Write-Host $State.reasoning -ForegroundColor DarkGray
    } else {
        Write-Host '[reasoning · 末尾3行 · Ctrl+O 展開]' -ForegroundColor DarkGray
        foreach ($line in Get-GoReasoningTail $State.reasoning) {Write-Host $line -ForegroundColor DarkGray}
    }
}
function Write-GoReasoningLive {
    param([hashtable]$State)
    $width=[Math]::Max(10,[Console]::WindowWidth)
    $overflow=$State.reasonTop+5-[Console]::BufferHeight
    if ($overflow -gt 0) {
        [Console]::SetCursorPosition(0,[Console]::BufferHeight-1)
        for ($i=0;$i -lt $overflow;$i++) {Write-Host ''}
        $State.reasonTop=[Math]::Max(0,$State.reasonTop-$overflow)
    }
    [Console]::SetCursorPosition(0,$State.reasonTop)
    for ($i=0;$i -lt $State.reasonRows;$i++) {Write-Host (' '*($width-1))}
    [Console]::SetCursorPosition(0,$State.reasonTop)
    Write-Host '[reasoning · Ctrl+O 展開]' -ForegroundColor DarkGray
    $lines=@(Get-GoReasoningTail $State.reasoning $width)
    foreach ($line in $lines) {Write-Host $line -ForegroundColor DarkGray}
    $State.reasonRows=1+$lines.Count
    $State.reasonTop=[Math]::Min($State.reasonTop,[Math]::Max(0,[Console]::BufferHeight-$State.reasonRows-1))
}
function Switch-GoReasoningView {
    param([hashtable]$State)
    if (-not $State.native -or $State.replaying) {return}
    $State.expanded=-not $State.expanded
    [Console]::Clear()
    $State.section=$null;$State.tools=@{};$State.reasoning='';$State.replaying=$true
    try {
        foreach ($event in $State.events) {$null=& $State.callback $event}
        if ($State.section -eq 'reasoning') {Write-GoReasoningSummary $State}
    } finally {$State.replaying=$false}
    # A running reasoning section continues below the repainted transcript.
    if ($State.section -eq 'reasoning') {
        if ($State.expanded) {$State.reasonRows=1}
        else {$State.reasonTop=[Math]::Max(0,[Console]::CursorTop-4);$State.reasonRows=4}
    }
}

# Native terminal editor; redirected input uses the same command loop without cursor control.
function Get-GoSessionList {
    param([string]$Directory,[string]$Workspace)
    if (-not (Test-Path -LiteralPath $Directory)) {return}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.session.json' -File) {
        try {
            $state=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($state.Version -ne 1 -or $state.Workspace -ne $Workspace) {continue}
            $first=@($state.History | Where-Object kind -EQ 'user' | Select-Object -First 1)
            $title=if ($first.Count) {($first[0].text -replace '\s+',' ')} else {'新しい会話'}
            [pscustomobject]@{Path=$file.FullName;Id=$state.Id;Model=$state.Model;Title=$title;Updated=$file.LastWriteTime;Messages=@($state.History).Count}
        } catch {Write-Verbose "Skipping invalid session: $($file.Name)"}
    }
}
function Show-GoTerminalStatus {
    param($Agent,[string]$SessionPath)
    $width=80
    try {$width=[Math]::Max(20,[Math]::Min(120,[Console]::WindowWidth))} catch {}
    Write-Host ('─'*$width) -ForegroundColor DarkCyan
    Write-Host ' power-agent ' -ForegroundColor Cyan -NoNewline
    Write-Host "$($Agent.Model) · $($Agent.Permission) · reasoning $($Agent.ReasoningEffort) / budget $($Agent.ThinkingBudget) · $($Agent.History.Count) messages" -ForegroundColor Gray
    Write-Host " $($Agent.Workspace)" -ForegroundColor DarkGray
    Write-Host " session: $([IO.Path]::GetFileName($SessionPath))" -ForegroundColor DarkGray
    Write-Host ' Enter 送信 · Alt+Enter 改行 · ↑↓ 履歴 · Ctrl+O reasoning · Ctrl+C 入力取消 · Ctrl+D 終了 · /help' -ForegroundColor DarkGray
}
function Read-GoTerminalInput {
    param([Collections.Generic.List[string]]$History,[switch]$Plain,[scriptblock]$OnToggleReasoning)
    if ($Plain -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {return Read-Host 'you'}
    $text='';$cursor=0;$index=$History.Count;$draft='';$rows=1
    $origin=[Console]::CursorTop
    $pendingKey=$null
    $oldControl=[Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput=$true
    try {
        while ($true) {
            $width=[Math]::Max(10,[Console]::WindowWidth)
            # Redraw only the input region; streamed transcript stays in terminal scrollback.
            [Console]::SetCursorPosition(0,$origin)
            for ($row=0;$row -lt $rows;$row++) {Write-Host (' '*($width-1));}
            $origin=[Math]::Max(0,$origin-([Math]::Max(0,$origin+$rows-[Console]::BufferHeight)))
            [Console]::SetCursorPosition(0,$origin)
            Write-Host '❯ ' -NoNewline -ForegroundColor Green
            Write-Host ($text.Replace("`n","`n  ")) -NoNewline
            # Cell positions account for wide CJK and combining characters.
            $line=0;$column=2;$targetLine=0;$targetColumn=2
            for ($i=0;$i -lt $text.Length;$i++) {
                if ($i -eq $cursor) {$targetLine=$line;$targetColumn=$column}
                $ch=$text[$i]
                if ($ch -eq "`n") {$line++;$column=2;continue}
                $category=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($text,$i)
                $cells=if ($category -in @([Globalization.UnicodeCategory]::NonSpacingMark,[Globalization.UnicodeCategory]::EnclosingMark) -or [char]::IsLowSurrogate($ch)) {0} elseif ([int]$ch -ge 0x1100 -and ([int]$ch -le 0x115f -or [int]$ch -ge 0x2e80)) {2} else {1}
                $column+=$cells
                if ($column -ge $width) {$line++;$column=$column % $width}
            }
            if ($cursor -eq $text.Length) {$targetLine=$line;$targetColumn=$column}
            $rows=$line+1
            $origin=[Math]::Min($origin,[Math]::Max(0,[Console]::BufferHeight-$rows))
            [Console]::SetCursorPosition($targetColumn,[Math]::Min([Console]::BufferHeight-1,$origin+$targetLine))
            if ($null -ne $pendingKey) {$key=$pendingKey;$pendingKey=$null} else {$key=[Console]::ReadKey($true)}
            if ($key.Modifiers -band [ConsoleModifiers]::Control) {
                if ($key.Key -eq 'O' -and $OnToggleReasoning) {
                    & $OnToggleReasoning
                    $origin=[Console]::CursorTop;$rows=1
                    continue
                }
                if ($key.Key -eq 'C') {$text='';$cursor=0;continue}
                if ($key.Key -eq 'D' -and -not $text) {Write-Host '';return '/exit'}
            }
            switch ($key.Key) {
                'Escape' {
                    # Unix terminals can send Alt+Enter as two keys: ESC followed by CR.
                    if (-not [Console]::KeyAvailable) {[Threading.Thread]::Sleep(30)}
                    if ([Console]::KeyAvailable) {
                        $next=[Console]::ReadKey($true)
                        if ($next.Key -eq 'Enter') {$text=$text.Insert($cursor,"`n");$cursor++}
                        else {$pendingKey=$next}
                    }
                }
                'Enter'  {
                    if ($key.Modifiers -band ([ConsoleModifiers]::Alt -bor [ConsoleModifiers]::Shift)) {$text=$text.Insert($cursor,"`n");$cursor++;continue}
                    [Console]::SetCursorPosition(0,[Math]::Min([Console]::BufferHeight-1,$origin+$rows-1));Write-Host ''
                    if ($text.Trim()) {$History.Add($text)}
                    return $text
                }
                'LeftArrow' {if ($cursor -gt 0) {$cursor--;if ($cursor -gt 0 -and [char]::IsLowSurrogate($text[$cursor])) {$cursor--}}}
                'RightArrow' {if ($cursor -lt $text.Length) {if ([char]::IsHighSurrogate($text[$cursor]) -and $cursor+1 -lt $text.Length) {$cursor++};$cursor++}}
                'Home' {$cursor=0}
                'End' {$cursor=$text.Length}
                'Backspace' {if ($cursor -gt 0) {$length=1;if ([char]::IsLowSurrogate($text[$cursor-1]) -and $cursor -gt 1) {$length=2};$cursor-=$length;$text=$text.Remove($cursor,$length)}}
                'Delete' {if ($cursor -lt $text.Length) {$length=1;if ([char]::IsHighSurrogate($text[$cursor]) -and $cursor+1 -lt $text.Length) {$length=2};$text=$text.Remove($cursor,$length)}}
                'UpArrow' {if ($index -eq $History.Count) {$draft=$text};if ($index -gt 0) {$index--;$text=$History[$index];$cursor=$text.Length}}
                'DownArrow' {if ($index -lt $History.Count) {$index++;$text=if ($index -eq $History.Count) {$draft} else {$History[$index]};$cursor=$text.Length}}
                default {if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {$text=$text.Insert($cursor,[string]$key.KeyChar);$cursor++}}
            }
        }
    } finally {[Console]::TreatControlCAsInput=$oldControl}
}
function Show-GoSessionTranscript {
    param($Agent,[scriptblock]$Renderer,[hashtable]$ConsoleState)
    if ($ConsoleState) {$ConsoleState.events.Clear();$ConsoleState.section=$null;$ConsoleState.tools=@{};$ConsoleState.reasoning=''}
    $names=@{}
    foreach ($message in $Agent.History) {
        if (-not $Renderer) {
            if ($message.kind -eq 'user') {Write-Host "❯ $($message.text)" -ForegroundColor Green}
            elseif ($message.kind -eq 'assistant' -and $message.text) {Write-Host $message.text -ForegroundColor White}
            elseif ($message.kind -eq 'result') {Write-Host "[tool result] $($message.text)" -ForegroundColor DarkGray}
            continue
        }
        switch ($message.kind) {
            'user' {$null=& $Renderer @{type='user';text=$message.text}}
            'assistant' {
                $null=& $Renderer @{type='assistant_start'}
                foreach ($call in $message.calls) {$names[$call.id]=$call.name}
                switch ($Agent.Protocol) {
                    'Chat' {foreach ($key in @('reasoning_content','reasoning','reasoning_text')) {if ($message.raw.ContainsKey($key) -and $message.raw[$key]) {$null=& $Renderer @{type='reasoning_delta';delta=$message.raw[$key]};break}}}
                    'Messages' {foreach ($block in $message.raw) {if ($block.type -eq 'thinking') {$null=& $Renderer @{type='reasoning_delta';delta=$block.thinking}}}}
                    'Responses' {foreach ($item in $message.raw) {if ($item.type -eq 'reasoning' -and $item.ContainsKey('summary')) {foreach ($part in $item.summary) {if ($part.ContainsKey('text')) {$null=& $Renderer @{type='reasoning_delta';delta=$part.text}}}}}}
                }
                if ($message.text) {$null=& $Renderer @{type='text_delta';delta=$message.text}}
                $null=& $Renderer @{type='assistant_end'}
            }
            'result' {
                $null=& $Renderer @{type='tool_start';callId=$message.callId;name=$names[$message.callId]}
                $null=& $Renderer @{type='tool_end';callId=$message.callId;text=$message.text;isError=$message.isError;details=@{}}
            }
        }
    }
}
function Select-GoTerminalItem {
    param([string]$Title,[string[]]$Labels,[switch]$Plain)
    if (-not $Labels.Count) {return -1}
    if ($Plain -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {return -1}
    $selected=0;$filter=''
    $origin=[Console]::CursorTop;$drawn=0
    $oldControl=[Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput=$true
    try {
        while ($true) {
            $matches=@(for ($i=0;$i -lt $Labels.Count;$i++) {if ($Labels[$i].IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0) {$i}})
            if ($matches.Count) {$selected=[Math]::Min($selected,$matches.Count-1)} else {$selected=0}
            $height=[Math]::Max(1,[Math]::Min(8,[Console]::WindowHeight-4))
            $start=[Math]::Max(0,$selected-$height+1)
            $width=[Math]::Max(10,[Console]::WindowWidth-1)
            [Console]::SetCursorPosition(0,$origin)
            for ($row=0;$row -lt $drawn;$row++) {Write-Host (' '*$width)}
            $origin=[Math]::Min($origin,[Math]::Max(0,[Console]::BufferHeight-$drawn))
            [Console]::SetCursorPosition(0,$origin)
            Write-Host "$Title · ↑↓ 選択 · Enter 決定 · Esc 取消" -ForegroundColor Cyan
            Write-Host "検索: $filter" -ForegroundColor Gray
            $visible=[Math]::Min($height,$matches.Count-$start)
            for ($row=0;$row -lt $visible;$row++) {
                $position=$start+$row
                $label=$Labels[$matches[$position]] -replace '[\r\n\x1b]',' '
                $limit=[Math]::Max(3,[int]($width/2)-3)
                if ($label.Length -gt $limit) {$label=$label.Substring(0,$limit-1)+'…'}
                $prefix=if ($position -eq $selected) {'❯ '} else {'  '}
                Write-Host ($prefix+$label) -ForegroundColor $(if ($position -eq $selected) {'Green'} else {'DarkGray'})
            }
            if (-not $matches.Count) {Write-Host '該当なし' -ForegroundColor DarkGray;$visible=1}
            $drawn=2+$visible
            $origin=[Math]::Min($origin,[Math]::Max(0,[Console]::BufferHeight-$drawn-1))
            $key=[Console]::ReadKey($true)
            switch ($key.Key) {
                'Escape' {return -1}
                'Enter' {if ($matches.Count) {return $matches[$selected]}}
                'UpArrow' {if ($selected -gt 0) {$selected--}}
                'DownArrow' {if ($selected -lt $matches.Count-1) {$selected++}}
                'Backspace' {if ($filter.Length) {$filter=$filter.Substring(0,$filter.Length-1);$selected=0}}
                default {if ($key.Modifiers -band [ConsoleModifiers]::Control -and $key.Key -eq 'C') {return -1};if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {$filter+=$key.KeyChar;$selected=0}}
            }
        }
    } finally {[Console]::TreatControlCAsInput=$oldControl;Write-Host ''}
}
