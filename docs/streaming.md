# Streaming API

`Invoke-GoAgent -OnEvent { param($event) ... }` emits events in order. Callback return values are discarded. Keep callbacks brief and avoid throwing exceptions.

| type | Fields | Timing |
| --- | --- | --- |
| `assistant_start` | `turn` | Before receiving a model response |
| `reasoning_delta` | `delta` | Public reasoning/summary fragments supplied by the provider |
| `text_delta` | `delta` | Assistant text fragments |
| `tool_call_delta` | `index`, `delta`; protocol-dependent `name`, `callId` | Tool-argument JSON fragments; not executable yet |
| `assistant_end` | `turn` | After response completion and validation |
| `tool_start` | `name`, `callId` | Before local tool execution |
| `tool_output_delta` | `name`, `callId`, `delta` | Incremental PowerShell stdout/stderr |
| `tool_end` | `name`, `callId`, `text`, `details`, `isError` | Tool completion or failure |
| `retry` | `attempt`, `maxRetries`, `delaySeconds`, `status` | Before a transient-error retry wait |
| `ui_tick` | None | During asynchronous network waits; ignore for transcript storage |
| `agent_error` | `message` | Failure/interruption; an exception also reaches the caller |

Reasoning events contain only provider-supplied public content. Messages signatures/redacted thinking and Responses encrypted_content remain in raw history for replay, without display events. Chat OpenCode reasoning deltas map to `reasoning_content` for replay.

Tool fragments may not be valid JSON. Do not execute them in a callback; wait for agent validation of the complete response. Multiple calls are assembled by index.

`-NoStream` buffers responses but still emits complete reasoning/text and live tool output. Test `-Transport` callbacks return complete provider responses and emit reasoning/text once.

## Cancellation and errors

Cancellation tokens propagate through SSE connection, waits, reads, retry delays, and tools. HTTP timeouts cover the entire streamed response. Premature EOF, invalid JSON, provider errors, and length/max_tokens responses fail without executing that response's tools. Partially received streams are not automatically retried.

Incomplete response history is discarded. Completed tool results and file changes remain. On cancellation, calls in the same assistant response receive matching error results before saving; the agent stops without starting another model response.

Buffered `-NoStream` uses Invoke-RestMethod, so HTTP reception follows TimeoutSeconds rather than cancellation-token interruption.

## CLI display

Reasoning appears in gray, showing the last three lines by default. Ctrl+O expands/collapses the complete reasoning in native interactive mode. Assistant text and tool output stream in receive order. Tool completion displays status/log paths without duplicating output already shown. `-HideReasoning` only changes presentation.

The module returns final assistant text in both modes. The CLI does not print that return value again. Use `Invoke-GoAgent` to obtain the final answer programmatically.
