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

# 単発実行。書込・編集・powershell は実行前に確認します。
./Start-GoAgent.ps1 -Workspace . -Prompt 'コードを調べて README を改善して'

# 読取専用（powershell も禁止）
./Start-GoAgent.ps1 -Workspace . -Permission ReadOnly -Prompt '構成を説明して'

# ツール名を表示
./Start-GoAgent.ps1 -Workspace . -Verbose
```

PowerShell 7 を `pwsh` として起動してください。Windows PowerShell 5.1 は対象外です。Windows の実行ポリシーでブロックされる場合は、所属組織の方針に従ってスクリプトの実行を許可してください。

## TUI とセッション（0.5.0）

対話起動は色付きのインライン TUI です。本文は白、reasoning は灰色、ツールは黄色、エラーは赤で区別します。入力欄の近くにモデル、権限、reasoning 設定、セッション名を表示します。

- `Enter` で送信、`Alt+Enter` で改行。左右・Home・End で編集、上下で入力履歴を選択。
- reasoning はストリーミング中も**末尾3行だけ**を更新表示。`Ctrl+O` で全文を展開／折りたたみ。応答後も切替可能で、再開した履歴にも対応します。
- `/model` と `/resume` は検索付き選択画面。上下で選び、Enter で決定、Esc で取消。
- 生成中は `Esc` または `Ctrl+C` で中断。入力中の `Ctrl+C` は入力取消、空の入力で `Ctrl+D` は終了。
- `-Plain` または入出力のリダイレクト時は行入力になります。選択画面は一覧とコマンド指定で操作します。

```powershell
./Start-GoAgent.ps1 -Workspace C:\src\project
# 同じ workspace の最新セッションを再開
./Start-GoAgent.ps1 -Workspace C:\src\project -Resume
# 保存先を変更
./Start-GoAgent.ps1 -SessionDirectory C:\agent-sessions
```

起動時から `sessions/<会話ID>.session.json` に自動保存します。依頼の受付時、ツール往復の完了時、設定変更時、終了時に保存します。`/new` は別ファイルで新規会話を開始し、以前の会話を残します。

```text
/resume                      セッションを選択
/resume 2                    一覧の2番を再開
/resume C:\agent-sessions\example.session.json
/save                        現在の保存先へ保存
/save C:\agent-sessions\copy.session.json
/model                       モデルを選択
/model gpt-6-luna            会話を保持してモデル変更
/reasoning High              Default / Low / Medium / High
/thinking 2048               Messages モデルの thinking budget
/thinking 0                  thinking budget の指定を解除
/retry                       失敗した依頼を手動再送
/new                         新規会話
/exit                        保存して終了
```

モデル変更では本文とツール呼出し・結果を新しい API 方式へ変換します。別モデルで使えない reasoning 署名・暗号化データ・応答 ID は引き継ぎません。reasoning 設定はモデル変更時に既定へ戻します。`/reasoning` は Chat／Responses 用、`/thinking` は Messages 用です。設定値が利用できるかは各モデルの仕様に従います。変更したモデルと reasoning 設定は保存・再開されます。

一時的な接続エラーや HTTP 408／429／500／502／503／504 は既定で最大2回、自動再送します。待ち時間と回数を黄色で表示し、SSE の `Retry-After` も尊重します。`-MaxRetries 0` で無効化できます。認証エラー、キャンセル、ストリーム受信後の途中切断は自動再送しません。実行済みツールは再送処理で実行し直さず、途中切断後は `/retry` で保存済みのツール結果から続けられます。

## 更新

```powershell
./Upgrade.ps1
# または API キー不要の起動オプション
./Start-GoAgent.ps1 -Upgrade
```

対話中は `/upgrade` でも更新できます。GitHub の `nakasyou/power-agent` の `main` を取得・解凍し、スクリプト自身のディレクトリへ上書きします。完了後はエージェントを再起動してください。`-Workspace` のプロジェクトを更新先にはしません。

セッション、`.env`、`.git`、独自ファイルは残します。配布スクリプト・README・docs・tests の同名ファイルへの変更は上書きされます。取得と検証が成功してから配置し、配置に失敗した場合は更新済みファイルを復元します。対話中は更新前に会話を自動保存します。Windows では配置したファイルを `Unblock-File` で解除します。実行ポリシーそのものは変更しません。

## ストリーミング表示（0.3.0）

CLI は既定で、モデルの reasoning と本文、実行中の PowerShell ツール出力を随時表示します。

```text
[reasoning]
モデルから返された reasoning または reasoning summary …
[assistant]
本文 …
[tool: powershell]
実行中のコマンド出力 …
exit_code: 0
```

```powershell
# 既定でストリーミング
./Start-GoAgent.ps1 -Workspace . -Model kimi-k3

# reasoning の表示だけを隠す。履歴からは削除しない
./Start-GoAgent.ps1 -Workspace . -HideReasoning

# LLM 応答を一括受信。ツールのリアルタイム出力は維持
./Start-GoAgent.ps1 -Workspace . -NoStream

# 対応する Chat／Responses モデルで reasoning effort を明示
./Start-GoAgent.ps1 -Workspace . -Model gpt-6-luna -ReasoningEffort Medium

# 対応する Messages モデルで thinking budget を明示
./Start-GoAgent.ps1 -Workspace . -Model minimax-m2.7 -ThinkingBudget 2048 -MaxTokens 8192
```

reasoning を返すか、全文・要約のどちらを返すかはモデル／provider の仕様によります。返されない reasoning を生成・表示することはありません。`-ReasoningEffort` と `-ThinkingBudget` は任意で、既定では provider の設定に従います。対応しないモデルでは指定しないでください。thinking budget は1024以上、`MaxTokens` 未満です。署名や暗号化された reasoning は再送用に保持し、画面には表示しません。

3種類の API の SSE に対応します。ツール引数は分割データを組み立て、応答完了後に実行します。途中切断、不完全な応答、キャンセルでは未完了の履歴を残しません。429 などの再試行はストリーム開始前だけ行い、表示済みの文章は再試行で重複させません。ストリーミング要求に対して JSON を返す互換サーバーは、完成した内容を一度表示します。

モジュール利用時は `-OnEvent` で受け取れます。`Invoke-GoAgent` の戻り値は引き続き最終本文です。

```powershell
Import-Module ./PSGoAgent.psd1
$agent = New-GoAgent -Workspace .
$answer = Invoke-GoAgent -Agent $agent -Prompt '調べて修正して' -OnEvent {
    param($event)
    switch ($event.type) {
        reasoning_delta   { Write-Host $event.delta -NoNewline -ForegroundColor DarkGray }
        text_delta        { Write-Host $event.delta -NoNewline }
        tool_start        { Write-Host "`nTool: $($event.name)" }
        tool_output_delta { Write-Host $event.delta -NoNewline }
        tool_end          { Write-Host "`nTool completed: $($event.name)" }
    }
}
```

イベント一覧とキャンセル・保存の扱いは [docs/streaming.md](docs/streaming.md) を参照してください。

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

Pi の標準ツールに合わせ、以下の7つをモデルへ公開します。Bash の代わりに Pi にもある `powershell` を使用します。外部の `rg`・`fd` は不要です。

| ツール | 動作 |
| --- | --- |
| `read` | テキストと画像の読取。テキストは開始行・行数指定、2000行／50 KiB 制限と継続案内 |
| `grep` | 正規表現／リテラル検索、大小文字指定、glob、前後の文脈、行番号、除外設定 |
| `find` | glob による再帰検索。隠し項目、除外設定、件数上限 |
| `ls` | 隠し項目を含む、名前順の一覧。ディレクトリには `/` を付加 |
| `write` | UTF-8 ファイルを作成・上書き。親ディレクトリ作成とファイル変更ロック |
| `edit` | `edits[]` による複数箇所の一括置換、Unicode 補助照合、BOM／改行保持、差分・パッチ |
| `powershell` | 別の `pwsh` で実行。終了コード、実行時間、出力更新、タイムアウト・キャンセル、全文ログ |

`grep` は既定100一致、`find` は1000件、`ls` は500件です。`limit` で変更できます。検索は `.gitignore`・`.ignore` の基本的なパターン、否定ルール、ネストした設定を扱います。`.git`・生成ログ用の `.power-agent`・シンボリックリンクは再帰しません。

### 編集

すべての置換は同じ元ファイルに照合します。1箇所でも未一致・曖昧・重複・重なりがある場合は、ファイルを変更しません。完全一致を優先し、未一致時には末尾空白・Unicode 正規化・引用符・ダッシュなどを補助照合します。補助照合で触れない行は元の内容を保持します。UTF-8 BOM と元の LF／CRLF を保持します。

```powershell
Import-Module ./PSGoAgent.psd1
$agent = New-GoAgent -Workspace . -Permission Ask
$result = Invoke-GoTool -Agent $agent -Name edit -Arguments @{
    path = 'app.ps1'
    edits = @(
        @{ oldText = '$port = 3000'; newText = '$port = 8080' }
        @{ oldText = '$debug = $false'; newText = '$debug = $true' }
    )
}
$result.details.diff               # 行番号付き差分
$result.details.patch              # unified patch
$result.details.firstChangedLine
```

同じパスへの `edit`／`write` は名前付き mutex で直列化します。検証後、一時ファイルから置換して保存します。旧形式の `oldText`／`newText`、JSON 文字列や単一オブジェクトで返された `edits` も受け付けます。

### 画像

`read` は PNG／JPEG／GIF／WebP をファイル内容から判別し、画像ブロックを返します。画像対応モデルへ送信する場合は `-EnableImages` を指定してください。指定しない場合、画像は API リクエストから除外し、その旨をモデルに伝えます。

```powershell
./Start-GoAgent.ps1 -Workspace . -Model gpt-6-luna -EnableImages -Prompt 'screenshot.png を読んで説明して'
```

画像は最大5 MiB、元のサイズで送信します。Pi の画像自動リサイズ・BMP 変換は未実装です。実際の画像対応可否は利用モデル／API の仕様に従います。

### コマンド出力とキャンセル

`powershell` の引数は `command` と任意の `timeout`（秒、小数可）です。Pi と同じく既定のコマンドタイムアウトはありません。モデルへ返す出力は末尾2000行／50 KiB。切り詰めた場合や中断時は全文を workspace 内の `.power-agent/output/*.log` に残し、`read` で確認できます。正常終了で切り詰めなかったログは削除します。非ゼロ終了はエラー結果としてモデルへ返します。子プロセスからは `OPENCODE_API_KEY` を除外します。

```powershell
$cts = [Threading.CancellationTokenSource]::new()
$cts.CancelAfter(5000)
Invoke-GoTool -Agent $agent -Name powershell -Arguments @{
    command = 'Get-ChildItem -Recurse'
    timeout = 30
} -CancellationToken $cts.Token -OnUpdate {
    param($update)
    Write-Host $update.text -NoNewline
}
$cts.Dispose()
```

`Invoke-GoAgent` でも `-CancellationToken`、`-OnEvent` と従来の `-OnToolUpdate` を指定できます。キャンセル時は実行中のコマンドをプロセスツリーごと停止し、完了済みのファイル変更は残します。ストリーミング HTTP 通信もキャンセルできます。`-TimeoutSeconds` は接続・受信・再試行の待機を含む1回のモデル応答全体の上限です。`-NoStream` の一括受信では HTTP タイムアウトが上限になります。

モデルのツール引数は許可した名前・引数に限定して検証します。ツールが失敗したり拒否されたりすると、エラーをモデルへ返して処理を継続します。1応答に複数のツール呼出しがある場合は順番に実行します。

ファイルツールは workspace 内のパスのみ許可し、シンボリックリンク／reparse point を拒否します。`powershell` は workspace を作業ディレクトリにしますが、**OS のサンドボックスではありません**。承認したコマンドはユーザーと同じ権限で動作し、workspace 外やネットワークにもアクセスできます。必要に応じて専用環境で実行してください。

権限モードは以下の3つです。

- `Ask`（既定）：`write`・`edit`・`powershell` の引数を表示して確認します。小文字 `y` で許可。
- `ReadOnly`：上記3ツールを禁止します。`read`・`grep`・`find`・`ls` のみをモデルへ公開。
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

指定したファイルに、API 応答とツール結果の往復が完了するたびに JSON を保存します。会話 ID、workspace、モデル、システム指示、履歴を復元します。画像送信設定も復元します。キーや承認コールバック、権限モードは保存しません。再開時も権限は既定で `Ask` です。保存ファイルには会話と読取内容・画像が含まれるので、公開リポジトリへ入れないでください。信頼できる自分のセッションファイルのみ再開してください。

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

既定では1依頼につき最大30回の API 呼出し、出力上限8192トークン、HTTP タイムアウト120秒です。`-MaxTurns`、`-MaxTokens`、`-TimeoutSeconds` で変更できます。テキスト読取・コマンド出力は2000行／50 KiB、検索と編集差分は50 KiB を目安に制限し、継続案内を付けます。一時的な接続エラーと HTTP 408／429／500／502／503／504 は2秒・4秒の待機後に最大2回再試行します（`-MaxRetries` で変更）。トークン上限で途切れた応答は完成した回答として扱いません。

LLM 応答は既定でストリーミング受信します。MCP、プラグイン、Pi の全ショートカット、履歴の自動圧縮、分岐、バックグラウンド実行は未実装です。長い会話では `/new` で切り替えてください。完了したファイル変更の自動ロールバックは行いません。ツールの対応範囲と Pi との差は [docs/tool-compatibility.md](docs/tool-compatibility.md) にまとめています。

追加のテスト依存なしで実行できます。

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

PowerShell 7.6.3 / Linux で、260件のアサーションと3方式の実 HTTP モック統合シナリオを検証済み。複数編集・失敗時の無変更・補助照合・BOM／改行保持・パッチの適用結果・別プロセス間の変更ロック、検索と除外設定、画像の API 形式変換、出力制限・更新・キャンセルに加え、認証・ツール往復・保存／再開・429再試行を確認しました。SSE の分割 UTF-8／複数行データ、reasoning／本文のリアルタイム通知、分割ツール引数、途中切断・キャンセル・タイムアウト、CLI の重複しない表示も検証しました。セッション自動保存、対話中のモデル／reasoning 変更、API 方式を跨ぐ履歴変換、再送回数と認証エラー時の停止も検証しました。Linux の擬似端末で Ctrl+O の生成中・入力中の切替、モデルの絞り込み選択、日本語の複数行入力を確認しました。OpenCode Go の API キーが提供されていないため実サービス接続は未検証です。Windows / macOS での実行は未検証です。

## 参考

実装は新規に PowerShell で記述しています。設計で参考にしたコードと対応関係は [docs/design.md](docs/design.md) を参照してください。

- [dfinke/PSAI](https://github.com/dfinke/PSAI)：PowerShell の agent／tool インターフェイスと会話ループ
- [badlogic/pi-mono](https://github.com/badlogic/pi-mono)：Pi coding agent の基本ツール、agent loop、OpenCode provider
- [OpenCode Go 公式ドキュメント](https://opencode.ai/docs/go/)：API 方式、モデル ID、セッションヘッダー

MIT License。
