# MVP 実装計画（M1〜M3）

- 対象: [PRD](../prd/PRD.md) の P0（F-01〜F-13）
- 推論ランタイム: (b) Swift ネイティブ（WhisperKit + MLX Swift）。根拠は [runtime-coreml-mlx.md](../research/runtime-coreml-mlx.md)
- 進め方: main（orchestrator + QA）がサブエージェントに Wave 単位で委譲する。各担当は git worktree で隔離し、main が QA 後に作業ブランチへマージする
- この文書が担当間の**契約の正典**。変更は main だけが行う

## 1. リポジトリ構成（契約）

```
app/                                  # XcodeGen。xcodeproj は生成物（git 管理外）
├── project.yml
└── ContextCapture/                   # アプリターゲット（SwiftUI + AppKit）
    ├── App/                          # @main, AppDelegate, AppCoordinator（Wave 2 で配線）
    ├── UI/                           # MenuBarExtra, Inbox, Detail, HUD, Toast, Settings, Onboarding
    ├── Resources/                    # Assets, Info.plist
    └── ContextCapture.entitlements
Packages/ContextCaptureKit/           # SwiftPM。ロジックはすべてここ（swift test で検証できる形）
├── Package.swift                     # Wave 0 が全依存を宣言。以降の担当は編集禁止（必要なら main へ報告）
├── Sources/
│   ├── CCCore/        # 型・プロトコル・パス解決。依存なし
│   ├── CCStore/       # SQLite（GRDB）、添付ファイル、ベクトル検索、保持期間
│   ├── CCCapture/     # ホットキー、前面アプリ/ウインドウ（AX）、URL（AppleScript）、ScreenCaptureKit、録音
│   ├── CCSTT/         # WhisperKit
│   ├── CCIntent/      # d1-3B on MLX Swift（プロンプト組み立て・readout・トークナイザ修正）
│   ├── CCEmbedding/   # EmbeddingGemma 2 on **Core ML**（FluidInference/embeddinggemma-2-coreml、テキスト・画像・融合。2026-10-10 変更）
│   ├── CCGuard/       # Vision OCR + 秘密情報パターン、マスク画像生成
│   ├── CCTriage/      # 非同期トリアージキュー、モデルのロード/解放
│   ├── CCModels/      # モデルの取得・変換・検証（HF ダウンロード、d1 抽出+8bit 量子化、チェックサム）
│   ├── CCMCP/         # MCP ツール実装（ストアを読む）
│   ├── cc-models/     # CLI: モデル準備（`cc-models prepare all`）
│   └── cc-mcp/        # CLI: stdio MCP サーバー（Claude Code / Hermes から起動される）
└── Tests/<Target>Tests/
scripts/check.sh                      # 全 QA コマンドの入口
```

- Swift tools 6.0、言語モード Swift 5（`swiftLanguageModes: [.v5]`）、macOS 15 以降
- アプリは**サンドボックスなし**（Accessibility / 他アプリへの Apple Events が必要）。Hardened Runtime、開発中はローカル署名
- 外部依存（Wave 0 で宣言）: GRDB.swift、WhisperKit、mlx-swift、mlx-swift-lm（MLXLMCommon / MLXLLM / MLXVLM）、swift-transformers（Tokenizers / Hub）、MCP swift-sdk、swift-argument-parser。版はスパイクで動いたもの（mlx-swift 0.32.3 / mlx-swift-lm 3.32.3 / swift-transformers 1.3.4 / WhisperKit 1.1.0）に合わせる

## 2. 保存先（契約）

| 用途 | 既定 | 上書き（テスト・開発用） |
|---|---|---|
| データ（SQLite・添付） | `~/Library/Application Support/ContextCapture/` | 環境変数 `CC_DATA_DIR` |
| モデル | `~/Library/Application Support/ContextCapture/Models/` | 環境変数 `CC_MODELS_DIR` |

- 添付: `captures/YYYY/MM/DD/<id>.<ext>`（スクショ・マスク版・音声）。DB にはデータルートからの相対パスで持つ
- モデル配置: `Models/d1-3b-text-q8/`、`Models/embeddinggemma-2/`、`Models/whisperkit/`。各ディレクトリに `manifest.json`（元リポジトリ・revision・sha256・変換手順の版）
- 開発中はスパイクの変換済みモデル `spikes/runtime/models/`（git 管理外・読み取り専用）を `CC_MODELS_DIR` で指してよい

## 3. 型とプロトコル（CCCore、契約の骨子）

Wave 0 がこの骨子で `CCCore` を実装し、確定したシグネチャは **`Packages/ContextCaptureKit/Sources/CCCore/` のソースが正典**（特に `Protocols.swift`）。Wave 0 での確定事項: プロトコル名は `Embedder`（MLXNN.Embedding との衝突回避）、`AudioRecording` は `start() async throws` / `stop()` / `cancel()` / `levels()`、Swift 名 `guardInfo` / `handoffs`（JSON キーは PRD どおり）、マスク版は `<id>-masked.<ext>`、`CC_DATA_DIR` を変えてもモデル位置は動かない、`RecordStore.count(_:)` と `InboxFilter` / `SearchHit` / `AttachmentKind` / `ModelSlot` を追加。

- `ContextRecord`: PRD §7 のフィールド（id は ULID 文字列、captured_at、app{name,bundleID}、window{title,frame}、url、extra[String:String]、screenshotPath / maskedScreenshotPath / audioPath（相対パス）、annotation{text, sttEngine, edited}、triage{intent, intentConfidence, mentionsDatetime, datetimeProbability, model}?、guard{status: pending|clear|needs_review|masked, findings[{kind, bbox(正規化 0–1・左上原点)}]}、handoffs[{to, at, via}]、notes[{author, text, at}]、status: inbox|done|archived）
- `Intent`: `todo / research / code / note / schedule`。確信度 < 0.7 は `intent = nil`（未分類）として保存し、確率は残す
- プロトコル（すべて `Sendable`、async）
  - `ContextCapturing.captureFrontmost() async -> CaptureContext`（**失敗しない**。取れなかった項目は nil）
  - `AudioRecording.start() throws` / `stop() async throws -> RecordedAudio{samples16kMono:[Float], duration, fileURL?}`
  - `SpeechTranscribing.prepare()` / `transcribe(samples:vocabulary:) -> Transcript{text, engine}`
  - `IntentClassifying.classify(text:) -> TriageResult`
  - `Embedding.dimension` / `embedQuery(_:)` / `embedDocument(text:title:image:)` → L2 正規化済み 256 次元
  - `SecretScanning.scan(image:) -> [SecretFinding]`
  - `RecordStore`: insert / update / get / list(filter) / delete / setEmbedding / search(vector, limit) / 添付の書き込みと URL 解決
- `ModelUnloadable`: `unload()`。トリアージは d1 を 10 分無使用で解放

## 4. コマンド（QA ゲート）

```zsh
scripts/check.sh            # 以下を順に実行し、1 つでも落ちたら非 0
  # 1) cd Packages/ContextCaptureKit && swift build && swift test（この環境では swift test でも MLX の metallib が作られる。確認済み）
  # 2) cd app && xcodegen generate && xcodebuild -scheme ContextCapture -configuration Debug build
```

- モデルが必要なテストは `CC_MODELS_DIR` にモデルが無ければ `XCTSkip`。main は QA 時に `CC_MODELS_DIR=spikes/runtime/models`（または準備済みの Models）を付けて回す
- MLX Swift のビルドには Metal Toolchain が必要（導入済み 2026-10-10）

## 5. Wave 計画

| Wave | 担当 | 内容 | 主な受け入れ条件 |
|---|---|---|---|
| 0 | scaffold | Package.swift（全依存）・全ターゲットの空実装・CCCore 完成・app/project.yml とメニューバーだけ出るアプリ・scripts/check.sh | check.sh が green、アプリが起動してメニューバーにアイコン |
| 1 | capture | CCCapture（F-02〜F-04）、ホットキー押下/解放、録音 16kHz | 単体テスト、実機確認手順書 |
| 1 | store | CCStore（§7 データモデル、添付、ベクトル検索、保持期間） | CRUD・検索・マイグレーションのテスト |
| 1 | stt | CCSTT（WhisperKit、カスタム語彙）、cc-models の whisper 準備 | fixtures 30 件で CER ≤ 9%、p90 ≤ 1.8 秒 |
| 1 | intent | CCIntent（d1 MLX Swift 8bit、トークナイザ修正）、cc-models の d1 準備 | 参照確率との最大差 ≤ 0.05、未見 22 件で ≥ 20/22、トークン列が HF と 104/104 一致 |
| 2 | ui | Inbox・詳細・HUD・トースト・設定・オンボーディング（F-01, F-06〜F-08, F-13 の UI） | 主要状態のスクショ、フェイク実装で動作 |
| 2 | wiring | AppCoordinator: ホットキー → 撮影+録音 → STT → 保存 → トースト（M1 の縦串） | **M1 動作確認（ユーザー実機）** |
| 3 | embedding | CCEmbedding を Core ML 版で（テキスト・画像前処理 bicubic・融合列の組み立て）、cc-models の embedding 準備（取得 → sha256 検証 → コンパイル）。ANE の初回特殊化はアプリ本体のプロセスで行う | 参照コサイン ≥ 0.995、融合 256 の R@3 ≥ 0.9 |
| 3 | guard+triage | CCGuard（OCR + パターン、マスク）、CCTriage（キュー・d1 解放）、検索 UI・意図ラベル UI | 14 画面で 4/4 検出・誤検知 0、トリアージの結合テスト |
| 4 | mcp | CCMCP + cc-mcp（6 ツール、needs_review 画像は返さない、削除不可） | MCP の結合テスト、Claude Code から list_inbox |
| 4 | e2e | 3 モデル同時常駐の実測、M2/M3 の受け入れ確認 | PRD §10 の非機能要件の実測表 |

## 5.1 埋め込みの決定（2026-10-10、[fluid-inference.md](../research/fluid-inference.md)）

- MLX Swift 手書き移植ではなく、`FluidInference/embeddinggemma-2-coreml`（revision `3f978dd` 固定、全ファイル sha256 検証）を Core ML で使う。実測: テキスト ANE 5ms・コサイン ≥0.9997、融合 256 R@3 0.933 / MRR 0.950（参照と同値）、融合 1 件 0.94 秒
- 画像トークンは参照と同じ 280 を既定とし、設定値にする（70 にすると 0.15 秒。変更時は索引の作り直しが要る）
- 実装上の必須事項: 画像縮小は HF と同じ bicubic を自前実装（CoreGraphics 補間ではコサイン 0.9938 で不合格）、推論ループは 1 件ごとに `autoreleasepool`（無いと 2.2GB まで膨張）、ANE キャッシュは実行バイナリ単位なので温めはアプリ本体で行う（`cc-models` で温めても効かない）
- FluidUse はライブラリ依存にしない（EmbeddingGemma 2 の Swift 実装は Apache-2.0 なので帰属表示付きで写してよい）

## 6. 持ち越し事項

- CCCore: 日時はミリ秒精度で保存されるため、`capturedAt` 等を生成時にミリ秒へ丸める（store 担当の提案。往復後の `==` を保証するため）
- Package.swift: CCStoreTests に GRDB を明示依存、CCCore の Fixtures 共有、CCIntentTests の Fixtures を resources/exclude に（警告解消）
- cc-models: `prepare` グループは main が持ち、各担当は葉コマンドだけ足す（stt マージ時に整理）
- モデル manifest を CCCore の共通型 `ModelManifest` にまとめる（d1 / whisper / embedding）
- CCTriage: 注釈中の特殊トークン文字列（`<|im_end|>` 等）は分類前に除去する（main 決定）。長い注釈の切り詰め、d1 の `load()` 3〜4 秒を非同期化するか
- CCModels: HF から取得した元モデル（5.8GB）を変換後に `Models/.downloads/` から消す
- アプリ本体（xcodebuild）でも d1 数値テストを回す（MLX カーネルの差で誤差が 0.05 に近づく恐れ。余裕 0.007）
- ホットキー: macOS 15 以降は ⌥ のみのショートカットを Carbon が拒否することがある。失敗時はアクセシビリティ権限で CGEventTap に切替（PRD §8.2 のとおりアクセシビリティ必須）。M1 実機で確認
- 画面収録の許可後はアプリの再起動が要る（オンボーディング文言に反映）
- NSAppleScript をバックグラウンドの直列キューで実行している（Apple はメイン推奨）。実機で問題があればメインへ
- wiring: `CaptureDiagnostics` の 3 関数をデバッグメニューから呼べるようにする
- UI: `InboxFilter.matches(_:)` を app から CCCore へ移す。MCP の `get_capture` は `RecordMarkdown.handoffScreenshotPath(_:)`（渡してよい画像の規則）を共有する
- UI: 除外アプリでスクショを撮らなかったときのトースト文言は出さない（PRD §6.3 に無い。現状維持）
- 調査書 runtime-coreml-mlx.md §4.2 のトークナイザ原因を更新（ignore_merges ではなく、swift-transformers の前分割が書記素クラスタ単位で照合し単独 LF に `[\r\n]` が一致しない）

## 7. 進捗（main が Wave ごとに更新）

- [x] 推論ランタイム調査（(b) Go、2026-10-10）
- [x] PRD を (b) に更新
- [x] Issue #1・作業ブランチ feat/1-mvp-app
- [x] Wave 0 scaffold（check.sh green、`swift test` で MLX が Metal 実行できることを確認）
- [x] 追加調査: FluidUse / embeddinggemma-2-coreml → 埋め込みは Core ML 版に切替（§5.1）
- [x] Wave 1 store（21 テスト成功、検索 1 万件 中央値 19.6ms。アプリは SQLiteRecordStore を 1 プロセス 1 インスタンスで持つこと。保持期間の削除はアプリ側が定期実行）
- [x] Wave 1 intent（トークン 104/104 一致、意図最大誤差 0.043、未見 21/22、p50 0.85 秒、8bit 2.9GB、Swift のみの変換が Python 版とビット一致）
- [ ] Wave 1 stt（dispatch 済み。worktree: ../memo-collector-worktrees/{store,stt,intent}、ブランチ wave1/*）
- [x] Wave 1 capture（47 テスト成功。権限・実機の経路は未検証 → docs/manual-tests/capture.md で M1 時にユーザー確認）
- [x] Wave 2 ui（check.sh green、スナップショット 12 枚 docs/ui-snapshots/。組み立て点は app/ContextCapture/App/AppEnvironment.swift の `// WIRING:`）
- [ ] Wave 2 wiring → M1 動作確認
- [ ] Wave 3 guard+triage（dispatch 済み。worktree ../memo-collector-worktrees/guard-triage）
- [ ] Wave 3 embedding（stt 完了後に dispatch。ANE の取り合いを避ける）
- [ ] Wave 4 mcp / e2e
- [ ] PR
