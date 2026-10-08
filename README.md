# PSGoAgent

A **PowerShell-only coding agent for OpenCode Go**, inspired by PSAI and Pi coding agent. Requires PowerShell 7.2 or later and standard .NET APIs. No Node.js, Python, additional PowerShell modules, or OpenCode CLI is required.

## Getting started

Obtain an API key and subscription from [OpenCode Go](https://opencode.ai/docs/go/).

```powershell
$env:OPENCODE_API_KEY = 'your-opencode-api-key'
./Start-GoAgent.ps1 -Workspace C:\src\project

# Run a single request
./Start-GoAgent.ps1 -Workspace . -Prompt 'Review the code and improve the README'

# Inspect without running commands or changing files
./Start-GoAgent.ps1 -Workspace . -Permission ReadOnly -Prompt 'Explain the project'

# List available models
./Start-GoAgent.ps1 -ListModels
```

Use `pwsh`, not Windows PowerShell 5.1. If Windows execution policy blocks scripts, follow your organization's policy before allowing execution.

## Terminal UI and sessions

Interactive mode uses a colored inline TUI: white assistant text, gray reasoning, yellow tools and retries, and red errors. The status area shows the model, permission mode, reasoning settings, workspace, and session filename.

- Enter sends; Alt+Enter inserts a newline. Left/Right/Home/End edit the input; Up/Down navigate input history.
- Reasoning streams into a panel showing the **last three lines**. Ctrl+O expands or collapses the full reasoning, during generation or afterward, including resumed history.
- `/model` and `/resume` open searchable selectors. Use Up/Down to select, Enter to confirm, and Esc to cancel.
- During streaming generation, Esc or Ctrl+C cancels. In the editor, Ctrl+C clears input; Ctrl+D exits when input is empty.
- `-Plain` or redirected input/output uses line input and command-based selection.

Sessions are saved automatically to `sessions/<conversation-id>.session.json` at startup, when a request is accepted, after complete tool exchanges, when settings change, and on exit. `/new` creates a separate file and preserves the previous conversation.

```powershell
# Resume the latest session for this workspace
./Start-GoAgent.ps1 -Workspace C:\src\project -Resume

# Choose a session directory or a specific session file
./Start-GoAgent.ps1 -SessionDirectory C:\agent-sessions
./Start-GoAgent.ps1 -Resume -SessionPath ./sessions/work.session.json
```

| Command | Action |
| --- | --- |
| `/resume` | Select a saved session |
| `/resume 2` | Resume entry 2 from the session list |
| `/resume PATH` | Resume a specific session file |
| `/save [PATH]` | Save to the current or specified path |
| `/model [NAME]` | Select or change the model without clearing the conversation |
| `/model NAME Chat` | Use an unknown model with an explicit protocol: Chat, Messages, or Responses |
| `/reasoning [Default\|Low\|Medium\|High]` | Inspect or change reasoning effort for Chat/Responses |
| `/thinking [BUDGET]` | Inspect or change the Messages thinking budget; 0 clears it |
| `/retry` | Resend a failed request or continue from completed tool results |
| `/new` | Start a new conversation |
| `/upgrade` | Update the installation |
| `/help` | Show commands |
| `/exit` | Save and exit |

Model changes convert conversation text, tool calls, and results to the new protocol. Foreign reasoning signatures, encrypted data, and response IDs are discarded. Model-specific reasoning settings reset to defaults when changing models. The selected model and reasoning settings are saved and restored. Support for individual reasoning settings depends on the model.

Session files restore the conversation ID, workspace, system instructions, model, history, and image/reasoning settings. API keys, approval callbacks, and permission modes are not saved. Resumed sessions default to `Ask`. Session files may contain file contents and images; keep them private and resume only trusted files.

## Upgrading

```powershell
./Upgrade.ps1
# No API key required
./Start-GoAgent.ps1 -Upgrade
```

The updater downloads and extracts `main` from `nakasyou/power-agent` on GitHub, then replaces distributed files in the script's own directory. Restart the agent afterward. The project selected with `-Workspace` is not the update destination.

Sessions, `.env`, `.git`, and custom files are preserved. Local changes to distributed scripts, README, docs, and tests are overwritten. Downloads are validated before installation; replaced files are restored if installation fails. Interactive upgrades save the current session first. On Windows, installed files are unblocked with `Unblock-File`; execution policy is not changed.

## Streaming and reasoning

Chat, Messages, and Responses SSE protocols are supported. Reasoning and assistant text stream separately. Tool argument fragments are assembled and validated before execution; PowerShell tool output streams while the command runs.

```powershell
./Start-GoAgent.ps1 -Model kimi-k3
./Start-GoAgent.ps1 -HideReasoning
./Start-GoAgent.ps1 -NoStream
./Start-GoAgent.ps1 -Model gpt-6-luna -ReasoningEffort Medium
./Start-GoAgent.ps1 -Model minimax-m2.7 -ThinkingBudget 2048 -MaxTokens 8192
```

`-HideReasoning` changes display only. `-NoStream` buffers model responses while retaining live tool output. Whether a model returns full reasoning, a summary, or no reasoning depends on the provider. Signatures and encrypted reasoning are retained for replay, but never displayed. Thinking budgets must be at least 1024 and less than `MaxTokens`.

Transient connection errors and HTTP 408/429/500/502/503/504 automatically retry up to twice, with 2/4-second delays. SSE requests respect `Retry-After`, capped at 60 seconds. Retry progress is displayed. Set `-MaxRetries 0` to disable retries. Authentication errors, cancellation, and partially received streams are not automatically retried. Completed tools are not rerun by the retry mechanism.

Incomplete responses are rolled back while completed tool exchanges are retained. A compatible server returning JSON for a streaming request is supported without duplicate output. See [streaming events](docs/streaming.md).

## Models and APIs

The default model is `glm-5.3-flash`. Known models automatically select their protocol. The `opencode-go/` prefix is accepted.

| Protocol | Example models | Endpoint |
| --- | --- | --- |
| Chat | glm-5.3-flash, kimi-k3 | `/chat/completions` |
| Messages | minimax-m2.7, qwen3.8-max | `/messages` |
| Responses | gpt-6-luna, grok-4.7 | `/responses` |

The base URL is `https://opencode.ai/zen/go/v1`. Each request includes a stable `x-opencode-session` conversation ID. Messages also includes `x-api-key` and `anthropic-version`.

```powershell
./Start-GoAgent.ps1 -ListModels
./Start-GoAgent.ps1 -Model custom-model -Protocol Chat
```

`-BaseUri` supports HTTPS and loopback HTTP for tests.

## Tools

Seven Pi-style tools are exposed. `powershell` replaces Bash to keep the runtime PowerShell-only. External `rg` and `fd` are not required.

| Tool | Behavior |
| --- | --- |
| `read` | Text offsets/limits, image detection, 2000-line/50-KiB truncation and continuation guidance |
| `grep` | Regex/literal search, case options, globs, context, line numbers, and exclusions |
| `find` | Recursive glob matching, hidden entries, exclusions, and result limits |
| `ls` | Sorted entries including hidden items; directories have a trailing `/` |
| `write` | UTF-8 creation/overwrite, parent directory creation, and mutation locking |
| `edit` | Batch `edits[]`, Unicode-assisted matching, BOM/newline preservation, diff and patch |
| `powershell` | Separate `pwsh` process, exit code, duration, live output, timeout/cancellation, and full logs |

Default result limits: grep 100 matches, find 1000 entries, ls 500 entries. Set `limit` to change them. Search supports basic `.gitignore`/`.ignore` patterns, negation, and nested rules. It does not recurse into `.git`, `.power-agent`, or symbolic links.

### Editing

Every replacement matches the same original file. Missing, ambiguous, duplicate, or overlapping matches leave the file unchanged. Exact matching is preferred; fallback matching normalizes trailing whitespace, Unicode, quotes, and dashes. Untouched lines keep their original content. UTF-8 BOM and LF/CRLF line endings are preserved.

```powershell
Import-Module ./PSGoAgent.psd1
$agent = New-GoAgent -Workspace . -Permission Auto
$result = Invoke-GoTool $agent edit @{
    path = 'example.ps1'
    edits = @(
        @{ oldText = 'first value'; newText = 'FIRST value' }
        @{ oldText = 'second value'; newText = 'SECOND value' }
    )
}
$result.details.diff
$result.details.patch
$result.details.firstChangedLine
```

A named mutex serializes `edit`/`write` on the same path. Validated changes are installed using a temporary file in the same directory. Legacy `oldText`/`newText`, JSON-string edits, and a single edit object are also accepted.

### Images

`read` detects PNG/JPEG/GIF/WebP from file contents. Enable API image attachments with `-EnableImages` and an image-capable model; otherwise only an explanatory text result is sent.

```powershell
./Start-GoAgent.ps1 -Model gpt-6-luna -EnableImages -Prompt 'Read screenshot.png and describe it'
```

Images are limited to 5 MiB and sent at their original size. Automatic resizing and BMP conversion are not implemented. Image support depends on the model/provider.

### Commands, permissions, and cancellation

The `powershell` tool takes `command` and an optional `timeout` in seconds, including fractions. There is no default command timeout. Results contain the last 2000 lines/50 KiB. Truncated or interrupted output is saved under `.power-agent/output/*.log` in the workspace. Successful, untruncated logs are removed. Nonzero exits are returned as tool errors. Child processes do not receive `OPENCODE_API_KEY`.

```powershell
$cancel = [Threading.CancellationTokenSource]::new()
Invoke-GoTool $agent powershell @{ command = 'Get-ChildItem'; timeout = 10 } `
    -CancellationToken $cancel.Token -OnUpdate { param($update) Write-Host $update.text -NoNewline }
$cancel.Dispose()
```

`Invoke-GoAgent` accepts `-CancellationToken`, `-OnEvent`, and the legacy `-OnToolUpdate`. Cancellation stops the command process tree and streaming HTTP, while retaining completed file changes. `-TimeoutSeconds` covers connection, reception, and retry waits for one streamed model response. Buffered `-NoStream` HTTP uses its timeout rather than cancellation-token interruption.

Tool arguments are validated against allowed names, types, and ranges. Failed or denied tools return errors to the model. Multiple calls in one response execute sequentially.

File tools are confined to the workspace and reject symbolic links/reparse points. **PowerShell commands are not OS-sandboxed**: approved commands run with your user permissions and can access other paths and the network.

| Permission | Behavior |
| --- | --- |
| `Ask` (default) | Show write/edit/powershell arguments and require lowercase `y` |
| `ReadOnly` | Expose only read/grep/find/ls; deny mutation and commands |
| `Auto` | Execute without confirmation; select explicitly |

A root `AGENTS.md` is included in initial instructions. Nested instruction discovery is not implemented.

## Module usage

```powershell
Import-Module ./PSGoAgent.psd1
$agent = New-GoAgent -Workspace . -Permission Ask
$answer = Invoke-GoAgent $agent 'Inspect this project' -SessionPath ./sessions/work.session.json -OnEvent {
    param($event)
    if ($event.type -eq 'text_delta') { Write-Host $event.delta -NoNewline }
}
Set-GoModel $agent gpt-6-luna
Set-GoReasoning $agent -Effort High
Invoke-GoAgent $agent 'Suggest improvements'
Save-GoSession $agent ./sessions/work.session.json
$agent = Import-GoSession ./sessions/work.session.json
```

Each agent owns independent history. Use `-Instructions` for additional instructions and `-Approve { param($name,$arguments) ... }` for a Boolean approval callback. A test `-Transport` receives a request with Uri/Headers/Body and returns a complete provider response. `Invoke-GoAgent` returns the final assistant text; the CLI displays events without printing that text again.

## Limits and validation

Defaults: 30 model turns per request, 8192 output tokens, and a 120-second HTTP timeout. Configure `-MaxTurns`, `-MaxTokens`, and `-TimeoutSeconds`. Text and command output use 2000-line/50-KiB limits; search and edit diffs are bounded around 50 KiB. Token-limited responses are treated as incomplete.

MCP, plugins, the complete Pi shortcut set, automatic context compaction, branching, and background execution are not implemented. Use `/new` for long conversations. Completed file changes are not automatically rolled back. See [tool compatibility](docs/tool-compatibility.md).

Run checks without additional test dependencies:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
pwsh -NoProfile -File ./tests/Tools.Tests.ps1
pwsh -NoProfile -File ./tests/Http.Tests.ps1
pwsh -NoProfile -File ./tests/Streaming.Tests.ps1
pwsh -NoProfile -File ./tests/Upgrade.Tests.ps1
pwsh -NoProfile -File ./tests/Terminal.Tests.ps1
pwsh -NoProfile -File ./tests/Console.Tests.ps1
pwsh -NoProfile -File ./tests/Retry.Tests.ps1
```

Validated on PowerShell 7.6.3/Linux with 262 assertions and three protocol HTTP integration scenarios. Coverage includes tools, edits/patches, locking, images, UTF-8 boundaries, SSE, retries, session persistence, protocol/model changes, and renderer callback scope. Native terminal checks covered reasoning expansion, model selection, and multiline input. Live OpenCode Go, Windows, and macOS execution remain unverified.

## References

Implementation and reference mappings: [design notes](docs/design.md).

- [dfinke/PSAI](https://github.com/dfinke/PSAI): PowerShell agent/tool interface and loop
- [badlogic/pi-mono](https://github.com/badlogic/pi-mono): agent loop, coding tools, and OpenCode Go providers
- [OpenCode Go documentation](https://opencode.ai/docs/go/): APIs, model IDs, and session headers

MIT license. See [LICENSE](LICENSE).

## Instructions and skills

Global instructions live in `~/.config/power-agent/AGENTS.md`; global skills live in its `skills/<name>/SKILL.md` directory. Change this root with `-GlobalConfigDirectory`.

Local instructions are read from AGENTS.md files between the nearest Git root and the workspace. Nested AGENTS.md instructions accompany file/search results only for their directory scope. Local skills in `.agents/skills` and `.power-agent/skills` override global skills with the same name. Skills use optional `name` and `description` frontmatter, appear in the system catalog, and are loaded on demand with the `skill` tool. Resuming a session rediscovers installed skills.

## OpenAI-compatible providers

```powershell
$env:OPENAI_API_KEY = 'your-key'
./Start-GoAgent.ps1 -Provider OpenAI -Model gpt-4.1
./Start-GoAgent.ps1 -Provider OpenAI -Model custom -BaseUri https://provider.example/v1
./Start-GoAgent.ps1 -Provider OpenAI -Model local -BaseUri http://localhost:1234/v1
./Start-GoAgent.ps1 -Provider OpenAI -Model gpt-4.1 -Protocol Responses
```

OpenAI-compatible providers default to Chat and accept arbitrary model names. Select Responses explicitly if supported. Use `OPENAI_API_KEY` or `-ApiKey`; unauthenticated loopback endpoints are allowed. OpenCode-specific headers are not sent to these providers. Provider/endpoint settings are saved in sessions; credentials are never saved there. Both API-key environment variables are excluded from command child processes.

## Codex device-code login

```powershell
./Start-GoAgent.ps1 -Login
# Visit the displayed OpenAI URL and approve the displayed code.
./Start-GoAgent.ps1 -Provider Codex -Model gpt-5.3-codex
./Start-GoAgent.ps1 -Logout
```

Enable device-code login in your ChatGPT settings if required. Codex uses ChatGPT subscription authentication rather than an OpenAI API key, requires streaming Responses, and automatically refreshes expiring tokens. Credentials are stored separately under the global config directory, protected with Windows user DPAPI or Unix owner-only permissions. Tokens never enter session files. Device login and token refresh are verified with mocks; live account authorization must be completed by the user.

## MCP

MCP supports stdio and Streamable HTTP (JSON or SSE replies), initialization/session headers, paginated tool discovery, progress notifications, structured results, and connection cleanup. Configure `~/.config/power-agent/mcp.json` or `.power-agent/mcp.json` in the workspace; local server definitions override global names. Use `-McpConfig PATH` for explicit configuration files.

```json
{
  "mcpServers": {
    "local": { "command": "pwsh", "args": ["-File", "C:/tools/server.ps1"] },
    "remote": { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ${MCP_TOKEN}" } }
  }
}
```

Only configure trusted servers: stdio commands launch when connecting. Tools are exposed as `mcp_SERVER_TOOL`; Ask mode confirms calls, and ReadOnly disables external tools. Explicit `env` and `headers` values may reference `${VARIABLE}`. MCP OAuth, resource browsing, prompts, sampling, and legacy HTTP+SSE transport are not implemented. Module users call `Connect-GoMcp` and `Disconnect-GoMcp` explicitly.

## Web search

```powershell
./Start-GoAgent.ps1 -Provider OpenAI -Model gpt-4.1 -EnableWebSearch
./Start-GoAgent.ps1 -Provider OpenAI -Model custom-chat -EnableWebSearch -WebSearchModel search-model -BaseUri https://provider.example/v1
```

The `web_search` function tool delegates to the same provider's Responses endpoint with the native `web_search` tool. It streams the summary and returns source titles/URLs as text and structured data without modifying conversation history. The provider and search model must support Responses native web search; generic Chat-only endpoints cannot supply this capability. Search settings persist in sessions.

Tool and command output is also collapsed to its last three lines by default. Ctrl+T expands/collapses tool panels while running or afterward. Reasoning uses Ctrl+O independently. Full streamed output remains available for expansion; saved sessions retain canonical tool results and full-log paths for truncated commands.
