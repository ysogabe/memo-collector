# 実機確認手順: MCP（Wave 4 mcp、`cc-mcp`）

`swift test --filter CCMCPTests` は一時データで `cc-mcp` を起動し、stdio で `initialize` → `tools/list` → `tools/call` を往復するところまで確かめている。
以下は Claude Code（や Hermes）に実際に登録して、エージェントから記録を読めるかを確かめる項目。**ここに書いた項目はどれも未検証**で、確認できたらチェックを付けて結果を書き込む。

## 0. 準備

### ビルド

```zsh
cd Packages/ContextCaptureKit
swift build --disable-keychain --product cc-mcp                     # デバッグ版: .build/debug/cc-mcp
swift build --disable-keychain -c release --product cc-mcp          # リリース版: .build/release/cc-mcp
```

実行ファイルの絶対パスを控える（例: `$(pwd)/.build/release/cc-mcp`）。Claude Code はこのパスを直接起動する。

### データの場所

- 既定はアプリと同じ `~/Library/Application Support/ContextCapture/`（`ContextCapture.sqlite` と `captures/`）。
- 別の場所を使うときは環境変数 `CC_DATA_DIR` を渡す。Claude Code がサーバーを起動するので、シェルで `export` しても効かない。`claude mcp add` の `-e` で渡す。
- DB が無いと `cc-mcp` は標準エラーに「データベースが見つからない: …」と出して終了コード 2 で終わる（DB を勝手に作らない）。先にアプリで 1 件以上記録しておく。
- アプリと同時に開いてよい（SQLite の WAL）。アプリが記録を追加すると、次のツール呼び出しから見える。

### Claude Code に登録

```zsh
# 既定のデータ場所を使う
claude mcp add context-capture -- /絶対パス/Packages/ContextCaptureKit/.build/release/cc-mcp

# データの場所を指定する（テスト用データなど）
claude mcp add context-capture -e CC_DATA_DIR=/path/to/data -- /絶対パス/Packages/ContextCaptureKit/.build/release/cc-mcp

# すべてのプロジェクトで使うならユーザースコープ
claude mcp add -s user context-capture -- /絶対パス/.../cc-mcp
```

確認: `claude mcp list` で `context-capture` が `✓ Connected`。Claude Code の中では `/mcp` で 6 ツール（list_inbox / search_captures / get_capture / add_note / mark_done / archive）が見える。
外すときは `claude mcp remove context-capture`。

### 手で JSON-RPC を流す（Claude Code を使わない切り分け）

```zsh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_inbox","arguments":{"limit":3}}}' \
  | CC_DATA_DIR=/path/to/data .build/debug/cc-mcp
```

標準出力には JSON-RPC の行だけが出る。ログ（起動・ツール名・所要時間）は標準エラーに出る。注釈本文やトークンはログに出ない。

## 1. 読み取り

| # | Claude Code への問いかけ | 期待結果 | 結果 |
|---|---|---|---|
| 1-1 | 「今日 Context Capture に入れた code の件を一覧して」 | `list_inbox`（`intent`="code"、`since`=今日の日付）が呼ばれ、今日の code の記録がアプリ名・ウインドウタイトル・注釈つきで新しい順に並ぶ。done / archived は出ない | [ ] |
| 1-2 | 「Context Capture の Inbox に何が溜まってる？」 | `list_inbox`（引数なし、既定 20 件）。未分類の記録は intent が null で、確信度が併記される | [ ] |
| 1-3 | 「Context Capture で adapter.ts の null の件を探して」 | `search_captures`。埋め込みが未実装の間は結果の `mode` が `keyword`（`fallback_reason`="embedder_unavailable"）で、注釈・タイトル・URL の部分一致で見つかる | [ ] |
| 1-4 | 1-1 の 1 件について「その件の詳細とスクショを見せて」 | `get_capture`（`include_image`=true）。guard が clear なら元画像、masked ならマスク版が表示され、Claude が画像の中身に言及できる | [ ] |
| 1-5 | 1-4 のあとアプリでその記録を開く | 受け渡し履歴に `claude-code`（クライアント名）/ `mcp` が 1 件増えている | [ ] |

## 2. 画像を渡さない規則（PRD F-10 / §9）

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 2-1 | トークンが写った画面をキャプチャし、guard が `needs_review` の記録を作る。Claude に「その件のスクショを見せて」 | 画像は返らず、「秘密情報の確認待ちのため画像は渡せません（…Inbox で確認すると…）」と説明される。受け渡し履歴は増えない | [ ] |
| 2-2 | 2-1 の記録をアプリでマスクして（`masked`）から同じ問いかけ | マスク版の画像が返る（トークン部分が塗られている） | [ ] |
| 2-3 | キャプチャ直後（ガードが走る前、`pending`）に問いかけ | 「秘密情報のチェックがまだ済んでいないため画像は渡せません」 | [ ] |
| 2-4 | 大きなスクショ（5K ディスプレイ全画面など、5MB 超） | 縮小された JPEG（長辺 2048px 以下）で返る | [ ] |

## 3. 状態更新・追記

| # | Claude Code への問いかけ | 期待結果 | 結果 |
|---|---|---|---|
| 3-1 | 「その件に『原因は lookup() の戻り値。PR #12 で修正』とメモしておいて」 | `add_note`。アプリの記録にメモが付き、書き手が `claude-code` | [ ] |
| 3-2 | 「その件は完了にして」 | `mark_done`。アプリの Inbox から消え、完了に入る | [ ] |
| 3-3 | 「それはアーカイブして」 | `archive`。削除はされない（アプリのアーカイブに残る） | [ ] |
| 3-4 | 「Context Capture のその記録を削除して」 | 削除ツールが無いのでできない、と返る（`archive` を提案するのは可） | [ ] |

## 4. 障害時

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 4-1 | `CC_DATA_DIR` を空のディレクトリにして登録 | `claude mcp list` で接続失敗。`cc-mcp` を手で起動すると「データベースが見つからない」と終了コード 2 | [ ] |
| 4-2 | アプリで記録を保存している最中に `list_inbox` を連打 | エラーにならない（WAL、ロック待ちは最大 10 秒） | [ ] |
