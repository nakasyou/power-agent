function New-GoConsoleRenderer {
    param([switch]$HideReasoning)
    $state=@{section=$null;tools=@{}}
    $hide=[bool]$HideReasoning
    {
        param($event)
        switch ($event.type) {
            'assistant_start' {$state.section=$null}
            {$_ -in @('reasoning_delta','text_delta')} {
                if ($event.type -eq 'reasoning_delta' -and $hide) {return}
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
            'agent_error' {if ($state.section) {Write-Host ''; $state.section=$null}}
        }
    }.GetNewClosure()
}
