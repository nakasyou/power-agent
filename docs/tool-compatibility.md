# Pi tool compatibility

Reference Pi commit: `1cedd32724abfcb0915f76cc61b6827e2c16dbad`. Core coding tools are reimplemented with a PowerShell-only runtime. This is not complete Pi or cross-platform compatibility.

| Pi feature | This implementation |
| --- | --- |
| read offset/limit, 2000 lines/50 KiB, continuation | Supported; text has no added line numbers, truncated ranges include guidance |
| PNG/JPEG/GIF/WebP | Supported; enable API attachments with `-EnableImages` |
| Automatic image resize and BMP conversion | Unsupported; original size, maximum 5 MiB |
| Batch edits against original text; reject overlap | Supported |
| Newline/BOM preservation and Unicode fallback | Supported for UTF-8; untouched lines preserved |
| Diff, unified patch, firstChangedLine | Supported; large LCS blocks fall back to whole-block replacement |
| File mutation queue | Named mutex serializes edit/write across processes on the same path; hardlink aliases use separate locks |
| grep regex/literal/ignoreCase/glob/context/limit | Supported using .NET regex, with different syntax/performance from ripgrep |
| find basename/path globs, recursion, limits | Supports `*`, `?`, `**`, character classes, and braces |
| .gitignore/.ignore | Basic patterns, negation, nesting, nested Git boundaries; no global ignores, info/exclude, or complete escape compatibility |
| ls sorting, hidden entries, directory markers, limits | Supported |
| bash | Replaced by powershell to meet the PowerShell-only requirement |
| powershell timeout, nonzero exit, live updates | Supported; no default timeout; timeout specified in seconds |
| Command tail truncation and full output | Last 2000 lines/50 KiB; full logs under workspace `.power-agent/output` |
| Cancellation and process-tree termination | CancellationToken and native CLI cancellation; completed mutations are retained |
| Tool results and structured output | text/content/details/structuredContent/isError |
| Custom operations/spawn hooks and Pi tool extension API | Unsupported |
| Platform-specific path correction | Unsupported; `@` prefixes and `~` are handled |

File tools reject paths outside the workspace and symbolic links, unlike Pi's unrestricted path access. Search also skips links. PowerShell commands are not OS-sandboxed.

Text read/edit loads files into memory; grep loads candidate lines into memory. Command output is spooled to disk. Direct runtime stderr is appended after normal output, so exact chronological ordering is not guaranteed.

Chat/Messages/Responses reasoning and text SSE, tool output streaming, inline TUI, sessions, and model/reasoning selection are supported. Live steering, context compaction, branching, and tool extension APIs remain unsupported.

Validation uses PowerShell 7.6.3/Linux with local tests and mock HTTP. Windows/macOS and live OpenCode Go/image-model connections remain unverified.
