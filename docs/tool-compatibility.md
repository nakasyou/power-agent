# Pi ツールとの対応範囲

参照した Pi はコミット `1cedd32724abfcb0915f76cc61b6827e2c16dbad` です。PowerShell だけで動作することを優先し、coding tools の主要機能を再実装しています。Pi 全体や全プラットフォームでの完全互換を保証するものではありません。

| Pi の機能 | 本実装 |
| --- | --- |
| read の offset／limit、2000行／50 KiB、継続案内 | 対応。本文に行番号は付けず、切り詰めた場合に範囲を案内 |
| PNG／JPEG／GIF／WebP 読取 | 対応。`-EnableImages` で API 送信を有効化 |
| 画像の自動リサイズ、BMP 変換 | 未対応。画像は最大5 MiB、元サイズで送信 |
| 複数 edits、元ファイルでの照合、重なり拒否 | 対応 |
| 改行／BOM 保持、Unicode 補助照合、変更しない行の保持 | 対応。UTF-8 が対象 |
| 差分、unified patch、firstChangedLine | 対応。LCS の計算量が大きいブロックは全ブロック置換に切替 |
| ファイル変更キュー | 名前付き mutex で edit／write をプロセス間で直列化。同一パスが対象で、ハードリンク別名は別ロック |
| grep の regex／literal／ignoreCase／glob／context／limit | 対応。正規表現は .NET の構文で、ripgrep の構文・速度と同一ではない |
| find の basename／パス glob、再帰、件数制限 | 対応。`*`、`?`、`**`、文字クラス、brace を扱う |
| .gitignore／.ignore | 基本パターン、否定、ネスト、ネストした Git 境界に対応。Git のグローバル除外・info/exclude・すべてのエスケープ規則は未対応 |
| ls のソート、隠し項目、ディレクトリ表示、limit | 対応 |
| bash | 使用しない。PowerShell のみという要件に合わせ powershell を公開 |
| powershell の timeout、非ゼロ終了、出力更新 | 対応。既定の実行タイムアウトなし。タイムアウトは秒で指定 |
| コマンド出力の末尾2000行／50 KiB、全文保存 | 対応。全文は workspace 内の `.power-agent/output` に保存 |
| ツールキャンセル、プロセスツリー停止 | `CancellationToken` と CLI の Ctrl+C に対応。完了した変更は巻き戻さない |
| ツール結果・構造化出力 | `Invoke-GoTool` は text／content／details／structuredContent／isError を返す |
| カスタム operations／spawn hook、Pi のツール拡張 API | 未対応 |
| macOS のスクリーンショット名などのパス補正 | 未対応。`@` 接頭辞と `~` は処理する |

workspace 外とシンボリックリンクを拒否する既存のファイルアクセス制限は維持しています。Pi の自由なパスアクセスとは異なります。検索もシンボリックリンクを辿りません。`powershell` 自体は OS サンドボックスではありません。

テキスト読取・編集はファイルをメモリに読込みます。grep は対象ファイルの行をメモリに読みます。コマンドの大量出力はディスクに転送します。正常なコマンドストリームはまとめて取得しますが、直接ランタイム stderr へ書かれた内容は末尾へ追加されるため、完全な時系列順序を保証しません。

検証は PowerShell 7.6.3 / Linux のローカルテストと HTTP モックで行いました。Windows／macOS、実 OpenCode Go、画像対応モデルの実サービス接続は未検証です。
