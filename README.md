# PSGoAgent

PSAI と Pi coding agent の設計を参考にした、**PowerShell だけで動作する OpenCode Go 用 coding agent** です。PowerShell 7.2 以上と標準の .NET API のみを使用します。Node.js、Python、PSAI、Pi、OpenCode CLI、追加 PowerShell モジュールのインストールは不要です。

## 起動

OpenCode Go の契約と API キーを用意してください。キーの取得先と利用条件は [OpenCode Go](https://opencode.ai/docs/go/) を参照してください。

```powershell
# PSGoAgent フォルダーで実行。キーは実際の値に置き換えてください。
$env:OPENCODE_API_KEY = 'your-opencode-api-key'

# 対話形式。対象プロジェクトのパスを指定。
./Start-GoAgent.ps1 -Workspace /path/to/project

# Windows の例
./Start-GoAgent.ps1 -Workspace C:\src\project

# 単発実行。書込・編集・shell は実行前に確認します。
./Start-GoAgent.ps1 -Workspace . -Prompt 'コードを調べて README を改善して'

# 読取専用（shell も禁止）
./Start-GoAgent.ps1 -Workspace . -Permission ReadOnly -Prompt '構成を説明して'

# ツール名を表示
./Start-GoAgent.ps1 -Workspace . -Verbose
```

PowerShell 7 を `pwsh` として起動してください。Windows PowerShell 5.1 は対象外です。Windows の実行ポリシーでブロックされる場合は、所属組織の方針に従ってスクリプトの実行を許可してください。

## モデルと API

既定のモデルは `glm-5.3-flash` です。既知のモデルは API 方式を自動選択します。`opencode-go/` 接頭辞も受け付けます。

| API 方式 | モデルの例 | 接続先 |
| --- | --- | --- |
| Chat | `glm-5.3-flash`, `glm-5.3`, `kimi-k3`, `deepseek-v4-pro` | `/chat/completions` |
| Messages | `minimax-m2.7`, `minimax-m3`, `qwen3.8-max`, `claude-haiku-5-5` | `/messages` |
| Responses | `gpt-6-luna`, `grok-4.7` | `/responses` |

ベース URL は `https://opencode.ai/zen/go/v1`。すべてのリクエストで会話ごとに固定の `x-opencode-session` を送信します。モデル表は 2026-10-07 に取得した公式ドキュメントに基づきます。モデル提供状況や利用可能なプランは変更されます。

```powershell
./Start-GoAgent.ps1 -ListModels
./Start-GoAgent.ps1 -Model kimi-k3 -Workspace .
./Start-GoAgent.ps1 -Model minimax-m2.7 -Workspace .
./Start-GoAgent.ps1 -Model gpt-6-luna -Workspace .

# 新しいモデルは公式の API 方式を確認して明示指定
./Start-GoAgent.ps1 -Model new-model-id -Protocol Chat -Workspace .
```

`-BaseUri` で HTTPS の互換サーバーに接続できます。その場合もキー名は `OPENCODE_API_KEY` です。HTTP はテスト用のループバック接続のみ許可しています。

## ツール

| ツール | 動作 |
| --- | --- |
| `read` | UTF-8 テキストを行番号付きで読取。開始行・行数を指定可能 |
| `list` | 隠しファイルを含む直下の一覧 |
| `write` | UTF-8 ファイルを作成・上書き。親ディレクトリも作成 |
| `edit` | 一意に一致する文字列だけを置換。未一致・複数一致は変更せずエラー |
| `shell` | 別の `pwsh -NoProfile -NonInteractive` プロセスで実行。stdout/stderr と終了コードを返す |

モデルのツール引数は許可した名前・引数に限定して検証します。ツールが失敗したり拒否されたりすると、エラーをモデルへ返して処理を継続します。1応答に複数のツール呼出しがある場合は順番に実行します。

ファイルツールは workspace 内のパスのみ許可し、シンボリックリンク／reparse point を拒否します。`shell` は workspace を作業ディレクトリにしますが、**OS のサンドボックスではありません**。承認したコマンドはユーザーと同じ権限で動作し、workspace 外やネットワークにもアクセスできます。必要に応じて専用環境で実行してください。

権限モードは以下の3つです。

- `Ask`（既定）：`write`・`edit`・`shell` の引数を表示して確認します。小文字 `y` で許可。
- `ReadOnly`：上記3ツールを禁止します。`read`・`list` のみ許可。
- `Auto`：確認せず実行します。自動実行したい場合に明示指定してください。

```powershell
./Start-GoAgent.ps1 -Workspace . -Permission Auto -Prompt 'テストを実行して問題を修正して'
```

workspace 直下の `AGENTS.md` があれば開始時に指示へ追加します。ネストした `AGENTS.md` の自動読込は未実装です。

## 保存・再開

```powershell
./Start-GoAgent.ps1 -Workspace . -SessionPath ./sessions/work.json
./Start-GoAgent.ps1 -SessionPath ./sessions/work.json -Resume

# 再開して単発の依頼を送信
./Start-GoAgent.ps1 -SessionPath ./sessions/work.json -Resume -Prompt '続けて修正して'
```

指定したファイルに、API 応答とツール結果の往復が完了するたびに JSON を保存します。会話 ID、workspace、モデル、システム指示、履歴を復元します。キーや承認コールバック、権限モードは保存しません。再開時も権限は既定で `Ask` です。保存ファイルには会話と読取内容が含まれるので、公開リポジトリへ入れないでください。信頼できる自分のセッションファイルのみ再開してください。

対話コマンド：`/exit`、`/new`（履歴と会話 ID をリセット）、`/save PATH`、`/help`。

## モジュールとして利用

```powershell
Import-Module ./PSGoAgent.psd1
$agent = New-GoAgent -Workspace . -Model kimi-k3
Invoke-GoAgent -Agent $agent -Prompt 'このプロジェクトを調べて'
Invoke-GoAgent -Agent $agent -Prompt '改善点を提案して'
Save-GoSession -Agent $agent -Path ./sessions/work.json
$restored = Import-GoSession -Path ./sessions/work.json
```

各 agent が独立した履歴を持ちます。`New-GoAgent` の `-Instructions` で指示を追加できます。埋込用途では `-Approve { param($name, $arguments) ... }` で承認を制御し、真偽値を返してください。テスト用の `-Transport` はリクエスト（Uri、Headers、Body）を受け取り API 応答オブジェクトを返します。

## 制限と検証

既定では1依頼につき最大30回の API 呼出し、出力上限8192トークン、HTTP タイムアウト120秒です。`-MaxTurns`、`-MaxTokens`、`-TimeoutSeconds` で変更できます。shell は既定60秒、ツール引数で最大300秒まで。モデルに返すツール結果は24000文字までです。429／500／502／503／504 の応答は2秒・4秒の待機後に最大2回再試行します。トークン上限で途切れた応答は完成した回答として扱いません。

この初版はテキスト中心の CLI です。応答は非ストリーミングで受信します。画像、MCP、プラグイン、Pi の全 TUI、履歴の自動圧縮、分岐、バックグラウンド実行は未実装です。長い会話では `/new` で切り替えてください。ツール編集の自動ロールバックは行いません。shell の大量出力は受信時にはメモリを使用します。

追加のテスト依存なしで実行できます。

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
pwsh -NoProfile -File ./tests/Http.Tests.ps1
```

PowerShell 7.6.3 / Linux で、49件のアサーションと3方式の実 HTTP モック統合シナリオを検証済み。認証ヘッダー、会話 ID、日本語、ツール往復、保存・再開、曖昧な編集、パス逸脱、権限制御、コマンドの失敗・タイムアウト、429再試行を確認しました。OpenCode Go の API キーが提供されていないため実サービス接続は未検証です。Windows / macOS での実行は未検証です。

## 参考

実装は新規に PowerShell で記述しています。設計で参考にしたコードと対応関係は [docs/design.md](docs/design.md) を参照してください。

- [dfinke/PSAI](https://github.com/dfinke/PSAI)：PowerShell の agent／tool インターフェイスと会話ループ
- [badlogic/pi-mono](https://github.com/badlogic/pi-mono)：Pi coding agent の基本ツール、agent loop、OpenCode provider
- [OpenCode Go 公式ドキュメント](https://opencode.ai/docs/go/)：API 方式、モデル ID、セッションヘッダー

MIT License。
