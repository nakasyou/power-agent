# ストリーミング API

`Invoke-GoAgent -OnEvent { param($event) ... }` が以下のイベントを順番に通知します。コールバックの戻り値は破棄します。重い処理や例外を発生させず、短い表示・記録処理に使用してください。

| type | 主なフィールド | タイミング |
| --- | --- | --- |
| `assistant_start` | `turn` | モデル応答の受信開始前 |
| `reasoning_delta` | `delta` | provider が返す公開 reasoning／summary の差分 |
| `text_delta` | `delta` | 本文の差分 |
| `tool_call_delta` | `index`, `delta`、方式により `name`, `callId` | ツール引数 JSON の差分。まだ実行しない |
| `assistant_end` | `turn` | 完成した応答の検証後 |
| `tool_start` | `name`, `callId` | ローカルツールの実行前 |
| `tool_output_delta` | `name`, `callId`, `delta` | PowerShell stdout／stderr の増分 |
| `tool_end` | `name`, `callId`, `text`, `details`, `isError` | ツールの完了・失敗時 |
| `agent_error` | `message` | 失敗・中断時。通常の例外も呼出元へ返す |

`reasoning_delta` は provider が提供した内容に限ります。Messages の signature、redacted thinking、Responses の encrypted_content は表示イベントに含めず、API 再送用の元応答に保持します。Chat の OpenCode `reasoning` 差分は再送時に `reasoning_content` へ対応付けます。

ツール引数の差分は有効な JSON とは限りません。コールバックで実行せず、完成した assistant 応答を agent が検証・実行するまで待ってください。複数のツール呼出しは index で組立てます。

`-NoStream` は一括受信を選択します。この場合も完成した reasoning／本文のイベントとツールの増分出力は通知します。テスト用 `-Transport` は引き続き完成した応答オブジェクトを返す契約で、reasoning／本文を一度通知します。

## キャンセルとエラー

`CancellationToken` は SSE の接続、待機、読取、429 などの再試行待機、ツールに伝播します。HTTP タイムアウトもストリーム全体へ適用します。完了前に切断された応答・不正 JSON・provider error・length／max_tokens の応答は失敗とし、その応答でツールを実行しません。部分的に受信したストリームは自動再試行しません。

モデル応答の未完了部分は保存しません。すでに実行して完了したツール結果とファイル変更は保持します。キャンセル中も同じ assistant 応答にあるツール呼出しへエラー結果を揃えて履歴を保存し、次のモデル応答へ進まず停止します。

`-NoStream` は従来の Invoke-RestMethod を使うため、HTTP 受信中の CancellationToken による停止は行わず TimeoutSeconds に従います。CLI の Ctrl+C は通常の PowerShell 中断として処理します。

## CLI 表示

既定では `[reasoning]`、`[assistant]`、`[tool: NAME]` を表示します。reasoning は灰色、本文とツール出力は受信した順に表示します。ツールの終了時に既表示の出力全文を再表示せず、終了コードや全文ログの場所を表示します。`-HideReasoning` は表示だけを隠し、推論設定や履歴を変えません。

ストリーミングと一括受信のいずれも、モジュールの戻り値は最終本文です。CLI はこの戻り値を再表示しません。プログラムから最終回答を取得する用途は `Invoke-GoAgent` を使ってください。
