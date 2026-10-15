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
- 開発用に 3 モデルをまとめた置き場 `spikes/dev-models/`（git 管理外。d1 と whisper はスパイクへのシンボリックリンク、埋め込みは HF から取得した実物）を `CC_MODELS_DIR` で指す
- 開発中はスパイクの変換済みモデル `spikes/runtime/models/`（git 管理外・読み取り専用）を `CC_MODELS_DIR` で指してよい

## 3. 型とプロトコル（CCCore、契約の骨子）

Wave 0 がこの骨子で `CCCore` を実装し、確定したシグネチャは **`Packages/ContextCaptureKit/Sources/CCCore/` のソースが正典**（特に `Protocols.swift`）。Wave 0 での確定事項: プロトコル名は `Embedder`（MLXNN.Embedding との衝突回避）、`AudioRecording` は `start() async throws` / `stop()` / `cancel()` / `levels()`、Swift 名 `guardInfo` / `handoffs`（JSON キーは PRD どおり）、マスク版は `<id>-masked.<ext>`、`CC_DATA_DIR` を変えてもモデル位置は動かない、`RecordStore.count(_:)` と `InboxFilter` / `SearchHit` / `AttachmentKind` / `ModelSlot` を追加。

- `ContextRecord`: PRD §7 のフィールド（id は ULID 文字列、captured_at、app{name,bundleID}、window{title,frame}、url、extra[String:String]、screenshotPath / maskedScreenshotPath / audioPath（相対パス）、annotation{text, sttEngine, edited}、triage{intent, intentConfidence, mentionsDatetime, datetimeProbability, model}?、guard{status: pending|clear|needs_review|masked, findings[{kind, bbox(正規化 0–1・左上原点)}]}、handoffs[{to, at, via}]、notes[{author, text, at}]、status: inbox|done|archived）
- `Intent`: `todo / research / code / note / schedule`。確信度 < 0.6 は `intent = nil`（未分類）として保存し、確率は残す
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
  # 2) cd app && xcodegen generate && xcodebuild -scheme ContextCapture -configuration Debug build && xcodebuild test
```

- 性能（レイテンシ）のアサートは `CC_PERF_ASSERT=1` のときだけ実行する（共有 ANE/GPU の負荷で 2〜4 倍揺れるため）。性能の受け入れは M1 と Wave 4 e2e で、他の処理を止めた状態で main が測る
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

## 5.2 受け入れ基準の定義（2026-10-11 main 決定）

- 意図の「≥ 80%」は**しきい値前の top-1 正解率（未見データ）**で測る（e2e: 未見 21/22、dev 25/30）。しきい値 0.7 による自動分類の割合（coverage、dev 24/30）は別指標とし、Issue #2 で実データから調整する
- メモリの「アイドル ≤ 4GB」は d1 解放後の状態で測る。トリアージ後 10 分の d1 常駐期間は「トリアージ中 ≤ 10GB」側で扱う（MLX キャッシュ上限の設定で 3.8GB まで下がる見込み）

## 6. 持ち越し事項

> 2026-10-10: Wave 5 cleanup / wiring-m2 で多くを消化。残りは「6.1 残件」に集約し、以下の旧リストは経緯として残す。

### 6.1 残件（Wave 6 polish で扱う）

- app の重複を CCCore 版へ寄せる: `InboxFilter.matches`、`ccRoundedToMilliseconds`。詳細ビューの保存を `RecordModifying.modify` に（今は get + update でトランザクションでない）
- `SearchIndexState` の JSON 定義がアプリと cc-mcp で二重 → CCCore へ
- cc-mcp の初回検索が遅い（初回 84 秒、2 回目以降も起動後最初は 16.5 秒）→ 状態が ready なら起動時に裏で温める。作り直し後に設定が同じでも読み直す件も
- 作り直しの途中で一部の索引が失敗しても ready にしてしまう → 失敗があれば ready にしない（再試行対象に残す）
- `TriageStepOutcome` に「未準備」を足し、未準備を失敗扱いにしない
- `D1ModelPreparer` にサイズだけの verify、`HubApi.snapshot` の進捗、`EmbeddingModelPreparer.prepare()` が `.unmanifested` を取り直す件
- CCMCP の検索を `search(vector:limit:statuses:)` に切り替え
- 起動直後に Whisper 読み込み中（約 11 秒）「モデルが未準備」と出る
- 開発用に記録を入れる正式な経路（cc-models か fixture）
- **アプリ本体（xcodebuild の Release）で d1 の数値テストを回す**（MLX カーネルの差で誤差が上限 0.05 に近づく恐れ。余裕 0.007）→ Wave 4 e2e で main が実施
- 見た目の残件（起動直後の「モデルが未準備」表示、`--debug` の 5 秒ポーリング）は別 Issue にする
- RSS は MLX / Core ML のメモリを反映しない → e2e のメモリはデバッグメニューの MLX アクティブ値と `footprint` で測る

### 6.0 旧リスト（経緯）

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
- triage の契約: 手動で意図を変えたら `TriageResult.manual(...)`（model == "user"）を書く、注釈編集後は `reprocess(id:)`、起動時に `resumePending()`
- CCStore に `idsWithoutEmbedding()` を追加（現状は零ベクトルで全件 search して代用、O(N)）。`modify(id:_:)` を CCCore の RecordStore に移す
- guard: 初回 OCR が 24 秒かかることがある（インストール後の最初のガード処理）。横並びのログインフォームのラベル右の値は未対応
- MCP: `search(vector:limit:)` に statuses の絞り込みを足す（archived が多いと件数不足）。append 系を RecordStore プロトコルに入れるか具体型依存を正式にするか。シンボリックリンク検査を CCPaths へ
- 署名の Team ID は PJH36NNFL6（証明書名の括弧内 3H5DM2CR45 は Team ID ではない）
- 保存形式: スクショ HEIC（ImageIO が WebP を書けない）、音声 WAV 16kHz/16bit
- wiring 所見: `WhisperModelPreparer.prepare()` が manifest 無しの既存モデルを取り直そうとする（既存採用の経路を足す）、`roundedToMilliseconds` を CCCore へ、`runHotKeyCheck` が同じ組み合わせを別登録する旨をコメントに、`AttachmentKind.screenshot` のコメントが .webp 前提、画面収録の権限状態が `.denied` を返さない、オンボーディングの容量表記
- 埋め込み: cc-mcp はテキスト塔を `.cpuAndGPU` で遅延ロード（案 A、main 決定。ANE は実行ファイルごとに約 2 分のコンパイルが要るため）。アプリでは `CoreMLEmbedder.prepare()` をモデル準備後にバックグラウンドで（初回 2.5〜3 分）。`indexSignature` を保存し、変わったら全件再埋め込み。ANE キャッシュの鍵は「実行ファイル + モデルのパス」と推測
- `Embedder` に `prepare()` を足す（または `ModelPreparable`）。`ModelSlot.embedding` のコメントを Core ML に直す。fluid-inference.md に torchvision 縮小の件を追記
- 調査書 runtime-coreml-mlx.md §4.2 のトークナイザ原因を更新（ignore_merges ではなく、swift-transformers の前分割が書記素クラスタ単位で照合し単独 LF に `[\r\n]` が一致しない）

## 7. 進捗（main が Wave ごとに更新）

- [x] 推論ランタイム調査（(b) Go、2026-10-10）
- [x] PRD を (b) に更新
- [x] Issue #1・作業ブランチ feat/1-mvp-app
- [x] Wave 0 scaffold（check.sh green、`swift test` で MLX が Metal 実行できることを確認）
- [x] 追加調査: FluidUse / embeddinggemma-2-coreml → 埋め込みは Core ML 版に切替（§5.1）
- [x] Wave 1 store（21 テスト成功、検索 1 万件 中央値 19.6ms。アプリは SQLiteRecordStore を 1 プロセス 1 インスタンスで持つこと。保持期間の削除はアプリ側が定期実行）
- [x] Wave 1 intent（トークン 104/104 一致、意図最大誤差 0.043、未見 21/22、p50 0.85 秒、8bit 2.9GB、Swift のみの変換が Python 版とビット一致）
- [x] Wave 1 stt（CER 6.75%（語彙の後処理）、空いた状態で p90 1.69 秒・負荷時 2.4〜6.6 秒。語彙プロンプトは CER を悪化させるため不採用）
- [x] Wave 1 capture（47 テスト成功。権限・実機の経路は未検証 → docs/manual-tests/capture.md で M1 時にユーザー確認）
- [x] Wave 2 ui（check.sh green、スナップショット 12 枚 docs/ui-snapshots/。組み立て点は app/ContextCapture/App/AppEnvironment.swift の `// WIRING:`）
- [x] Wave 2 wiring（check.sh green、アプリのテスト 25 件、署名 Apple Development / Team PJH36NNFL6 + Hardened Runtime、metallib 同梱）
- [x] M1〜M3 実機確認（ユーザー、2026-10-11 0:45〜1:30、記録 11 件）: ホットキー（Carbon）・撮影・ウインドウ名・URL（Safari 7/9）・STT・保存・トリアージ・索引・3 モデルの取得と変換・d1 の 10 分解放が動作。押下→録音開始 p50 48ms / p90 55ms（≤150ms 合格）。解放→保存 10.2 秒（n=1）は、旧 e2e ハーネスのアプリが同じデータ置き場でモデル取得・変換・ANE コンパイル中だったため参考値 → 単独起動で再計測。アプリの挙動に問題なし（ユーザー評価）
  - 意図: 11 件中 7 件が未分類（note と research の間で迷う）→ Issue #2 で実データから調整
  - 観測性: キャプチャ 1 件ごとのログ（保存・所要時間・エラー）が debug レベルで保存されない → notice 以上に（注釈本文は出さない）
  - STT: 固有名詞の誤り（コンテクトキャプチャー、デシオン、スピーチCPP）→ 設定の固有名詞辞書で補正できるか確認
- [x] Wave 3 guard+triage（14 画面 4/4・誤検知 0、PEM・重なり・余白のマスク漏れ 4 件をセキュリティレビュー指摘で修正、56 テスト、本物の d1 で結合テスト）
- [x] Wave 3 embedding（コサイン最小 0.9988、融合 256 R@3 0.933 / MRR 0.950、release で融合 0.59 秒・テキスト 6ms、ピーク 375MB。HF の縮小は torchvision の uint8 bicubic とビット一致させた）
- [x] Wave 4 mcp（27 テスト、stdio 往復の結合テストあり。画像は clear/masked のみ・データルート外を読まない。cc-mcp の埋め込みは Wave 5/6 で `makeQueryEmbedder` → `WarmingQueryEmbedder`（.cpuAndGPU、起動時に裏で温める）に置き換え済み）
- [x] Wave 5 wiring-m2（アプリのテスト 46 件。非 fake 起動で resumePending・needs_review 判定・埋め込み初回準備 158 秒・d1 の 10 分解放・cc-mcp の vector 検索をログで確認。実機確認手順 docs/manual-tests/m2-m3.md）
- [x] Wave 5 cleanup（§6 の Packages 側 10 項目。自前コードの警告 0）
- [x] Wave 6 polish（7 項目。パッケージ 304 件・アプリ 54 件のテスト。degraded 中のアプリ検索はベクトルを続けて注意書き。d1 は manifest がある置き場で余計なファイルがあると取り直しになる）
- [x] Wave 4 e2e（docs/e2e/report.md。解放→保存 p90 1.72〜1.80 秒（続けて録ると 4.38 秒、起動後最初の 1 件は 5.2〜8.4 秒）、アイドル CPU 0.02%、アイドルメモリ 121MB〜591MB、トリアージ中ピーク 7.22GB、d1 の SwiftPM / Xcode 差 0.0。修正項目は Wave 7）
- [x] Wave 7 fix（arm64 限定＋CCEmbedding の Float16 を `#if arch(arm64)`、MLX キャッシュ上限 256MB（ピーク 7.2→4.1GB）、Whisper の起動時ウォームアップ（初回 STT 5.2→1.4 秒）、キャプチャ中のトリアージ一時停止（効果は実機で確認: m1.md W7-5）、notice ログ、隠れた HUD のアニメーションが CPU を使い続ける不具合。アプリのテスト 66 件）
- [x] main による e2e 再計測（docs/e2e/report.md §9: 解放→保存 p90 1.39〜1.54 秒、続けて録ると 2.69 秒、初回 STT 1.38 秒、ピーク 4.09GB、d1 誤差不変）
- [x] セキュリティレビュー（信頼度 7 以上 0 件。7 未満の 2 件は #3）（security-review skill）
- [x] PR #4 作成（Refs #1。フォロー Issue #2 意図の調整、#3 供給網・表示の残件）
- [x] PR #4 自己レビュー（A: code-review 9 件、C: テスト・QA 17 件 → 統合して修正必須 11 / フォロー Issue #5 / praise）
- [x] Wave 8 review-fix（修正必須 11 件。check.sh green、アプリのテスト 71 件。`CC_MODELS_DIR` 指定時は受け入れテストが skip せず失敗する）
- [x] W7 修正後の単独起動での実機確認（2026-10-11 11:05）: 押下→録音開始 46〜71ms、一時停止は正常。解放→保存は 1.45 秒（録音 1.9 秒）と 6.68 秒（録音 5.8 秒、STT 6.59 秒。トリアージの取り合いは無し）。同じ記録が 2 回トリアージされる重複を発見
- [x] Wave 9 stt-latency（`capture saved` に sttBreakdown を出す。温度フォールバック説は不支持・アイドル後の低電力化説は反証。有力はエンコーダ（ANE）の混雑で 3〜4 倍に膨らむ現象＝フォールバック 0 で STT 5 秒を実測。設定は変更せず。トリアージの重複防止）
- [ ] 実機で再確認（遅い 1 件が出たら sttBreakdown で原因を確定）

## 2026-10-15 MVP受け入れ

M3 24GiBでユーザーが実キー・マイク・Safariを使い、HUD/保存通知/注釈/スクショ/URLを確認。連続10組20件の保存失敗0、押下→録音開始P90 81ms（最大141ms）、解放→保存P90 1525ms。通知・操作の異常なしをユーザーが確認した。採用基準70%では20件すべて未分類だったが、未分類を減らすため60%を採用して #1 を閉じることをユーザーが明示した。保存済み確率への適用結果はtodo19件・未分類1件で、記録の書換えや20件の独立した品質評価を意味しない。

[受け入れ結果・未確認項目](../research/mvp-acceptance-20261015.md)。意図の多様な実データ評価・既存記録の再処理は #2、helper/OS電源policyは #10で継続する。追加のマスク操作・ベクトル検索・OS異常系などの手動確認はチェック表に残し、未実施を合格にしない。M1/16GBの実測や全負荷条件の速度保証とは扱わない。
