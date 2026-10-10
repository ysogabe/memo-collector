# 元会話の要約（ChatGPT「音声入力タスク管理構想」）

- 出典: https://chatgpt.com/share/6ac7523f-cdf4-83ee-8868-ae4522f2c60e
- 取得日: 2026-10-08
- 位置づけ: PRD と LP の**一次ソース**。構想がどう変わったかと、そこで決まった設計原則を残す。

## 1. 構想の変遷

| 段階 | ユーザーの問い・発言 | 到達した結論 |
|---|---|---|
| ① Voice Todo | 「Apple Silicon の Mac で GPU を使った音声入力ソフトを作れるか。TODO をサクッと入力して管理したい」 | 作れる。GPU を使うこと自体を目的にせず、**GPU / ANE を使い分ける**。音声認識アプリではなく **Quick Capture アプリ**にする。Push-to-Talk（⌥Space 長押し）で入れる |
| ② 機能を削る | 「Super Productivity を試したが、機能が多すぎて面倒になった」 | 高機能タスク管理を土台にしない。**入力時に分類させない**。Inbox / Today 中心。「毎日使って不便だと確認できるまで機能を足さない」 |
| ③ Context Capture へ | 「タスク管理は Hermes / Claude Code に任せたい。今開いている URL を自動で取りたい。カレントウインドウのスクショでもいい。**今見ている画面に音声でアノテーションを付ける**イメージ」 | アプリの正体は **「今見ているコンテキストを音声でキャプチャして後工程に渡す」**ツール。URL とスクショは**両方を Best Effort で取る**。取れなくてもキャプチャ自体は絶対に失敗させない |
| ④ 会議中の横メモ | 「オンライン会議中にさっとメモできる？マイクは複数アプリで使える？」 | macOS では Zoom / Teams / Meet と同じマイクを同時に使える。Zoom 側をミュートしていても自アプリでは録音できる。**Meeting mode** を用意。ただし**会議音声の録音は MVP に入れない**（参加者の同意・社内ポリシー） |

最終的な呼び名: **「Voice Todo」ではなく「AI 向け Context Annotation Tool」**。
`画面 + URL + アプリ + 時刻 + 自分の一言` をワンアクションで残し、何をするかは後から Hermes / Claude Code が判断する。

## 2. 会話で決まった設計原則（PRD に引き継ぐ）

1. **入力摩擦を最小にする**: ホットキー → 話す → 離す で終わり。優先度・タグ・プロジェクト・期限の入力は求めない。
2. **キャプチャ時は重い処理をしない**: OCR / VLM はキャプチャ時に走らせない。画像 + 音声 + 最低限メタデータを保存して終わる。解釈は後段で行う。
3. **Best Effort なコンテキスト取得**: Screenshot / Window / App は原則必須、URL・ファイルパス等は取れたら補足。失敗してもレコードは残す。
4. **タスク管理はしない**: 判断と実行は Hermes / Claude Code 側。アプリはローカルに Context Record をきれいに溜める入口。
5. **Push-to-Talk**: 常時待ち受けのウェイクワードは使わない（誤登録・プライバシー・電力）。
6. **差し替え可能な構造**: `STTProvider`（FluidAudio/ANE を第一候補、whisper.cpp/Metal を比較用）、`ContextProvider`（Screenshot / URL / Window / App）、`Intent → Adapter`（LocalInbox / Hermes / Claude Code / Reminders …）。
7. **MCP は 4〜6 個で足りる**: `list_inbox` / `get_capture` / `add_capture` / `complete` 程度。

## 3. 会話に出た技術要素

- 録音: `AVAudioEngine`、VAD
- STT: FluidAudio + Parakeet JA（Core ML / ANE、M2 で平均約 209ms・約 28.9 倍速と紹介）、whisper.cpp（Metal）、MLX Whisper
- 画面: `NSWorkspace.frontmostApplication`、Accessibility API（フォーカス中ウインドウ）、ScreenCaptureKit（`SCWindow` / `SCContentFilter` / `SCScreenshotManager` で 1 枚だけ撮る）
- 権限: マイク、画面収録（Screen & System Audio Recording）、アクセシビリティ
- 将来: Core Audio Process Tap で会議アプリの出力音声を取る（同意問題があり MVP 外）、VS Code のファイル・行、Finder の選択ファイル、Terminal の cwd
- UI: `MenuBarExtra` 常駐、録音中 HUD、保存後 1 秒ほどのトースト、Context Inbox（一覧 → 詳細 → [Hermes へ] [Claude へ] [削除]）

## 4. 会話で触れられていない／未決の論点（本リポジトリで扱う）

- 後段の「解釈」をどこで誰が行うか（ローカル小型モデルか、Hermes 側の LLM か）
- Inbox の検索・重複整理
- 秘密情報（API キー、パスワード）がスクショに写り込んだまま外部エージェントに渡るリスク
- これらに LiquidAI d1 系と EmbeddingGemma 2 が使えるか → `docs/poc/` で検証
