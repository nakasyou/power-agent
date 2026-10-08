# Server-Sent Events transport and provider-specific response assembly. PowerShell/.NET only.
function Publish-GoEvent([scriptblock]$Callback,$Event) {
    if ($Callback) { $null=& $Callback $Event }
}

function New-GoStreamState([string]$Protocol) {
    @{protocol=$Protocol;done=$false;finish=$null;raw=@{role='assistant';content=''};tools=@{};blocks=@{};arguments=@{};response=$null}
}

function Add-GoStreamEvent($State,[string]$Data,[scriptblock]$OnEvent) {
    if ($Data -eq '[DONE]') {
        if ($State.protocol -eq 'Chat' -and $State.finish) {$State.done=$true}
        return
    }
    try {$event=ConvertFrom-Json -InputObject $Data -AsHashtable -ErrorAction Stop}
    catch {throw 'Malformed JSON in provider stream.'}
    if ($event -isnot [Collections.IDictionary]) {throw 'Invalid provider stream event.'}
    if ($event.ContainsKey('error') -or ($event.ContainsKey('type') -and $event.type -in @('error','response.failed','response.incomplete'))) {throw 'Provider reported a streaming error or incomplete response.'}
    switch ($State.protocol) {
        'Chat' {
            if (-not $event.ContainsKey('choices') -or $event.choices.Count -eq 0) {return}
            foreach ($choice in $event.choices) {
                if ($choice.ContainsKey('index') -and $choice.index -ne 0) {continue}
                if ($choice.ContainsKey('finish_reason') -and $choice.finish_reason) {$State.finish=$choice.finish_reason}
                if (-not $choice.ContainsKey('delta') -or -not $choice.delta) {continue}
                $delta=$choice.delta
                if ($delta.ContainsKey('content') -and $delta.content) {
                    $State.raw.content+=[string]$delta.content
                    Publish-GoEvent $OnEvent @{type='text_delta';delta=[string]$delta.content}
                }
                foreach ($field in @('reasoning_content','reasoning','reasoning_text')) {
                    if ($delta.ContainsKey($field) -and $delta[$field] -is [string] -and $delta[$field].Length -gt 0) {
                        $replayField=if ($field -eq 'reasoning') {'reasoning_content'} else {$field}
                        if (-not $State.raw.ContainsKey($replayField)) {$State.raw[$replayField]=''}
                        $State.raw[$replayField]+=$delta[$field]
                        Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$delta[$field]}
                        break
                    }
                }
                if ($delta.ContainsKey('reasoning_details')) {
                    if (-not $State.raw.ContainsKey('reasoning_details')) {$State.raw.reasoning_details=@()}
                    # Opaque replay metadata is preserved, never rendered as reasoning.
                    foreach ($detail in $delta.reasoning_details) {
                        $last=if ($State.raw.reasoning_details.Count -gt 0) {$State.raw.reasoning_details[-1]} else {$null}
                        if ($last -and $detail.type -in @('reasoning.text','reasoning.summary') -and $last.type -eq $detail.type) {
                            $key=if ($detail.type -eq 'reasoning.text') {'text'} else {'summary'}
                            if ($detail.ContainsKey($key)) {$last[$key]+=$detail[$key]}
                            if ($detail.ContainsKey('signature')) {$last.signature=$detail.signature}
                        } else {$State.raw.reasoning_details+=@($detail)}
                    }
                }
                if ($delta.ContainsKey('tool_calls')) {
                    foreach ($tool in $delta.tool_calls) {
                        $index=[int]$tool.index
                        if (-not $State.tools.ContainsKey($index)) {$State.tools[$index]=@{id='';type='function';function=@{name='';arguments=''}}}
                        $call=$State.tools[$index]
                        if ($tool.ContainsKey('id') -and $tool.id) {$call.id+=$tool.id}
                        if ($tool.ContainsKey('function')) {
                            if ($tool.function.ContainsKey('name')) {$call.function.name+=$tool.function.name}
                            if ($tool.function.ContainsKey('arguments')) {
                                $call.function.arguments+=$tool.function.arguments
                                Publish-GoEvent $OnEvent @{type='tool_call_delta';index=$index;callId=$call.id;name=$call.function.name;delta=$tool.function.arguments}
                            }
                        }
                    }
                }
            }
        }
        'Messages' {
            if (-not $event.ContainsKey('type')) {throw 'Messages stream event has no type.'}
            switch ($event.type) {
                'message_start' {$State.response=$event.message}
                'content_block_start' {
                    $index=[int]$event.index;$State.blocks[$index]=$event.content_block
                    $block=$State.blocks[$index]
                    if ($block.type -eq 'text' -and $block.text) {Publish-GoEvent $OnEvent @{type='text_delta';delta=$block.text}}
                    if ($block.type -eq 'thinking' -and $block.thinking) {Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$block.thinking}}
                }
                'content_block_delta' {
                    $index=[int]$event.index
                    if (-not $State.blocks.ContainsKey($index)) {throw 'Messages delta arrived before its content block.'}
                    $block=$State.blocks[$index];$delta=$event.delta
                    switch ($delta.type) {
                        'text_delta' {$block.text+=$delta.text;Publish-GoEvent $OnEvent @{type='text_delta';delta=$delta.text}}
                        'thinking_delta' {$block.thinking+=$delta.thinking;Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$delta.thinking}}
                        'signature_delta' {
                            if (-not $block.ContainsKey('signature')) {$block.signature=''}
                            $block.signature+=$delta.signature
                        }
                        'input_json_delta' {
                            if (-not $State.arguments.ContainsKey($index)) {$State.arguments[$index]=''}
                            $State.arguments[$index]+=$delta.partial_json
                            Publish-GoEvent $OnEvent @{type='tool_call_delta';index=$index;callId=$block.id;name=$block.name;delta=$delta.partial_json}
                        }
                    }
                }
                'content_block_stop' {
                    $index=[int]$event.index
                    if ($State.arguments.ContainsKey($index)) {
                        try {$State.blocks[$index].input=ConvertFrom-Json -InputObject $State.arguments[$index] -AsHashtable}
                        catch {throw 'Incomplete tool JSON in Messages stream.'}
                    }
                }
                'message_delta' {
                    if ($event.delta.ContainsKey('stop_reason')) {$State.finish=$event.delta.stop_reason}
                    if ($event.ContainsKey('usage') -and $State.response) {$State.response.usage=$event.usage}
                }
                'message_stop' {$State.done=$true}
            }
        }
        'Responses' {
            if (-not $event.ContainsKey('type')) {throw 'Responses stream event has no type.'}
            switch ($event.type) {
                'response.output_text.delta' {Publish-GoEvent $OnEvent @{type='text_delta';delta=$event.delta}}
                {$_ -in @('response.reasoning_summary_text.delta','response.reasoning_text.delta')} {Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$event.delta}}
                'response.function_call_arguments.delta' {
                    Publish-GoEvent $OnEvent @{type='tool_call_delta';index=$event.output_index;delta=$event.delta}
                }
                {$_ -in @('response.completed','response.done')} {$State.response=$event.response;$State.done=$true}
            }
        }
    }
}

function Complete-GoStream($State) {
    if (-not $State.done) {throw 'Provider stream ended before its completion marker. Partial response was discarded.'}
    switch ($State.protocol) {
        'Chat' {
            if ($State.tools.Count -gt 0) {$State.raw.tool_calls=@($State.tools.Keys | Sort-Object | ForEach-Object {$State.tools[$_]})}
            if ($State.raw.content -eq '') {$State.raw.content=$null}
            @{choices=@(@{finish_reason=$State.finish;message=$State.raw})}
        }
        'Messages' {
            if (-not $State.response -or -not $State.finish) {throw 'Incomplete Messages stream metadata.'}
            $State.response.content=@($State.blocks.Keys | Sort-Object | ForEach-Object {$State.blocks[$_]})
            $State.response.stop_reason=$State.finish
            # Do not permit a tool block to execute unless its complete JSON was parsed.
            foreach ($index in $State.arguments.Keys) {
                $parsed=ConvertFrom-Json -InputObject $State.arguments[$index] -AsHashtable -ErrorAction Stop
                $State.blocks[$index].input=$parsed
            }
            $State.response
        }
        'Responses' {
            if (-not $State.response) {throw 'Missing final Responses stream object.'}
            $State.response
        }
    }
}

function Read-GoSseResponse($Stream,[string]$Protocol,[Threading.CancellationToken]$CancellationToken,[scriptblock]$OnEvent) {
    $reader=[IO.StreamReader]::new($Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
    $state=New-GoStreamState $Protocol
    $data=[Collections.Generic.List[string]]::new();$size=0
    try {
        while (-not $state.done) {
            $CancellationToken.ThrowIfCancellationRequested()
            $line=Wait-GoNetworkTask ($reader.ReadLineAsync().WaitAsync($CancellationToken)) $CancellationToken $OnEvent
            if ($null -eq $line) {
                if ($data.Count -gt 0) {Add-GoStreamEvent $state ($data -join "`n") $OnEvent}
                break
            }
            if ($line.Length -eq 0) {
                if ($data.Count -gt 0) {Add-GoStreamEvent $state ($data -join "`n") $OnEvent;$data.Clear();$size=0}
                continue
            }
            if ($line.StartsWith('data:')) {
                $value=$line.Substring(5);if ($value.StartsWith(' ')) {$value=$value.Substring(1)}
                $size+=$value.Length
                if ($size -gt 16MB) {throw 'Provider SSE event exceeds 16 MiB.'}
                $data.Add($value)
            }
            # Comments, event, retry and id fields are valid SSE metadata, not JSON.
        }
        Complete-GoStream $state
    } finally {$reader.Dispose()}
}

function Send-GoStreamRequest($Agent,$Request,[Threading.CancellationToken]$CancellationToken,[scriptblock]$OnEvent) {
    if (-not $Request.Headers.ContainsKey('Authorization') -and -not ([uri]$Request.Uri).IsLoopback) {throw 'Set the provider API key (OPENCODE_API_KEY or OPENAI_API_KEY), or use -ApiKey.'}
    $client=[Net.Http.HttpClient]::new();$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $timeout=[Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $timeout.CancelAfter([TimeSpan]::FromSeconds($Agent.TimeoutSeconds));$token=$timeout.Token
    try {
        for ($attempt=0;$attempt -le $Agent.MaxRetries;$attempt++) {
            $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$Request.Uri)
            $response=$null;$stream=$null
            try {
                foreach ($key in $Request.Headers.Keys) {$null=$message.Headers.TryAddWithoutValidation($key,[string]$Request.Headers[$key])}
                $null=$message.Headers.TryAddWithoutValidation('Accept','text/event-stream')
                $message.Content=[Net.Http.StringContent]::new(($Request.Body | ConvertTo-Json -Depth 100 -Compress),[Text.Encoding]::UTF8,'application/json')
                try {$response=Wait-GoNetworkTask ($client.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$token)) $token $OnEvent}
                catch {
                    if ($token.IsCancellationRequested) {throw}
                    if ($attempt -lt $Agent.MaxRetries) {Wait-GoRetry $attempt $Agent.MaxRetries $token $OnEvent;continue}
                    throw 'OpenCode streaming connection failed. Check network and endpoint.'
                }
                $status=[int]$response.StatusCode
                if (-not $response.IsSuccessStatusCode) {
                    if ($status -in @(408,429,500,502,503,504) -and $attempt -lt $Agent.MaxRetries) {
                        $delay=0
                        if ($response.Headers.RetryAfter) {
                            if ($response.Headers.RetryAfter.Delta) {$delay=$response.Headers.RetryAfter.Delta.TotalSeconds}
                            elseif ($response.Headers.RetryAfter.Date) {$delay=($response.Headers.RetryAfter.Date-[DateTimeOffset]::UtcNow).TotalSeconds}
                        }
                        Wait-GoRetry $attempt $Agent.MaxRetries $token $OnEvent $status $delay
                        continue
                    }
                    throw "OpenCode request failed (HTTP $status). Check model, API key, plan quota and network."
                }
                if ($response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.MediaType -eq 'application/json') {
                    # Compatible servers may ignore stream=true. Emit the complete text once.
                    $json=Wait-GoNetworkTask ($response.Content.ReadAsStringAsync($token)) $token $OnEvent
                    $result=ConvertFrom-Json -InputObject $json -AsHashtable
                    Publish-GoBufferedResponse $Agent $result $OnEvent
                    return $result
                }
                if (-not $response.Content.Headers.ContentType -or $response.Content.Headers.ContentType.MediaType -ne 'text/event-stream') {throw 'Expected text/event-stream from provider.'}
                $stream=$response.Content.ReadAsStreamAsync($token).GetAwaiter().GetResult()
                # Never retry a partially received stream: already displayed deltas must not duplicate.
                return Read-GoSseResponse $stream $Agent.Protocol $token $OnEvent
            } finally {if ($stream) {$stream.Dispose()};if ($response) {$response.Dispose()};$message.Dispose()}
        }
    } catch {
        if ($CancellationToken.IsCancellationRequested) {throw [OperationCanceledException]::new('Request cancelled.',$CancellationToken)}
        if ($timeout.IsCancellationRequested) {throw "OpenCode request timed out after $($Agent.TimeoutSeconds) seconds."}
        throw
    } finally {$timeout.Dispose();$client.Dispose()}
}

function Publish-GoBufferedResponse($Agent,$Response,[scriptblock]$OnEvent) {
    if (-not $OnEvent) {return}
    $r=$Response | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    switch ($Agent.Protocol) {
        'Chat' {
            $raw=$r.choices[0].message
            foreach ($key in @('reasoning_content','reasoning','reasoning_text')) {
                if ($raw.ContainsKey($key) -and $raw[$key]) {Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$raw[$key]};break}
            }
        }
        'Messages' {foreach ($block in $r.content) {if ($block.type -eq 'thinking') {Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$block.thinking}}}}
        'Responses' {foreach ($item in $r.output) {if ($item.type -eq 'reasoning' -and $item.ContainsKey('summary')) {foreach ($part in $item.summary) {if ($part.ContainsKey('text')) {Publish-GoEvent $OnEvent @{type='reasoning_delta';delta=$part.text}}}}}}
    }
    $complete=ConvertFrom-GoResponse $Agent $Response
    if ($complete.text) {Publish-GoEvent $OnEvent @{type='text_delta';delta=$complete.text}}
}
