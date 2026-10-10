# Wave 4 e2e 計測報告（3 モデル同時常駐）

PRD §10 の非機能要件と §8.1 のモデル配置を、本物の 3 モデル（Whisper large-v3-turbo / EmbeddingGemma 2 / d1-3B 8bit）を
1 プロセスに同時に載せた状態で測った。入口は `scripts/e2e.sh`、生データは `docs/e2e/results/*.json`。
**本計測は 2 回目の全体実行 `20261011-015350-*`**（02:07〜02:37）。1 回目 `20261011-004409-*` は計測を乱すものが並行していたので使わない（§1.1）。

> **結論**
> - **解放 → 保存（ハーネスで測れる部分）**: トリアージなし p90 **1.72 秒**、録音時間を挟んでトリアージ並行（実使用に近い）p90 **1.80 秒** → 2.0 秒以内。
>   **間を空けずに続けて録るとトリアージと ANE を取り合い p90 4.38 秒**。所要時間のほぼすべてが文字起こし（STT）で、符号化・保存は合わせて 5ms 以下。
>   ただし実機の値には録音停止・撮影の待ち・トースト表示が加わり、**アプリ起動後の最初の 1 件は STT だけで 5〜8 秒**かかる（§7 問題 3）
> - 品質は PoC・個別計測と一致: 意図 top-1 25/30、ガード 4/4・誤検知 0（保存形式の HEIC でも）、検索 R@3 0.933 / MRR 0.950、CER 7.67%
> - **d1 の数値は SwiftPM / Xcode / アプリ本体で同一**（SwiftPM と Xcode の確率差 0.0。MLX の `default.metallib` の sha256 が 3 つとも一致）。
>   PyTorch 参照との最大差 0.0426（上限 0.05、余裕 0.0074）
> - メモリ（プロセスの phys_footprint）: トリアージ中のピーク 7.2GB（≤ 10GB 合格）、d1 解放後 0.6GB（≤ 4GB 合格）。
>   d1 常駐中（トリアージ後 10 分）は 7.1GB で、うち 3.6GB は **MLX のバッファキャッシュ（上限未設定）**。上限 256MB にするとピーク 4.1GB、速さは変わらない（§8）
> - アイドル CPU: **0.02%**（60 秒で CPU 時間 0.01 秒。≤ 1% 合格）
> - 押下 → 録音開始 ≤ 150ms はこのハーネスでは測れない → **実機確認（`docs/manual-tests/m1.md` §2 の計測表）**

## 1. 計測条件

| 項目 | 値 |
|---|---|
| 機種 | **Mac15,12（Apple M3）/ 24GB**。PRD §10 の基準機（M1 / 16GB）ではない |
| OS | macOS 27.0.1（26A434） |
| ビルド | Release。SwiftPM は `swift test -c release -Xswiftc -enable-testing`（他のテストターゲットが `@testable import` するため。最適化は -O のまま）。Xcode は `-configuration Release ENABLE_TESTABILITY=YES`。アプリは `xcodebuild -configuration Release ARCHS=arm64`（§7 問題 1） |
| モデル | `CC_MODELS_DIR=/Users/yoshio/works/60-misc/memo-collector/spikes/dev-models`（読み取りのみ。各段の後に `find -newer` で書き込みが無いことを確認済み） |
| データ | 一時ディレクトリ（周・条件ごとに新しいストア。(c) のアプリも一時ディレクトリ） |
| 評価データ | `poc/fixtures/dataset.json`（注釈 30・画面 14・テキストクエリ 10）、`poc/fixtures/audio/*.wav`、`poc/fixtures/screens/*.png` |
| 周回 | 3 周 × 3 条件 × 30 件。条件の順は周ごとにずらした |
| 除外したもの | 埋め込みの ANE 初回コンパイル（xctest バイナリが変わると走る。1 回目 98 + 24 秒）・モデルの読み込み・各モデルの初回呼び出しは計測から除き、`model_loads` に別記 |
| 本計測の uptime | (a) 前 `2:09 load 4.35 4.49 4.87` → 後 `2:27 load 2.15 2.70 3.83`、(b) 前 `2:27 load 2.15` / Xcode 前 `2:31 load 1.75`、(c) 前 `2:34 load 2.72` → 後 `2:36 load 2.04` |
| 本計測中の他のプロセス | ContextCapture は 0 個、他の担当は無し。(a) 開始時の上位は XProtectRemediatorColdSnap 99%・syspolicyd 40%（OS の定期スキャン）。(a) の各周開始時の 1 分 load は 1.5〜8.9（`rounds_detail[].load_average_before`。8.9 は 1 周目の paced の直前のみ） |

### 1.1 使わなかった時間帯（重要）

- **0:45〜1:52 頃、ユーザーの実機確認と旧ハーネスのアプリが同じデータ置き場で同時に動いていた**（その時間帯の値は使わない）。
  00:46:49 にこの worktree の Release ビルド（`DerivedData/e2e-app/.../ContextCapture.app`）が引数・`CC_*` 環境変数なしで起動され（PID 9834）、
  既定のデータ置き場 `~/Library/Application Support/ContextCapture` でオンボーディング → モデル準備（00:48〜00:50）→ 埋め込みの ANE 初回コンパイル
  （00:50〜00:55、270 秒）→ トリアージ 2 件の後、CPU 6% 前後・footprint 4.8GB で常駐し、01:52:48 にメニューから終了された。
  このハーネスはこのプロセスにも既定のデータ置き場にも触れていない。同じ時間帯は xcodebuild（このハーネス以外）・ANECompilerService も重なり、
  1 分 load は 3.7〜10.4 だった
- その時間帯の 1 回目の全体実行（`20261011-004409-*`）は参考として残す。解放 → 保存はトリアージなしでも p90 3.76 秒と、本計測（1.72 秒）の倍だった。
  負荷で STT がどれだけ落ちるかの参考値になる（m1.md の「空いた状態で p90 1.69 秒、負荷時 2.4〜6.6 秒」と同じ傾向）

## 2. PRD §10 の要件に対する結果

| 要件 | 目標 | 結果（本計測） | 判定 |
|---|---|---|---|
| 解放 → 保存トースト | p90 ≤ 2.0 秒 | ハーネス（STT + 符号化 + 保存。録音停止・撮影待ち・トースト表示は含まない）: トリアージなし p50 1.58 / **p90 1.72** / 最大 2.03、録音時間を挟んでトリアージ並行 p50 1.33 / **p90 1.80** / 最大 1.98、間を空けずにトリアージ並行 p50 3.03 / **p90 4.38** / 最大 5.47 | 通常の使い方（録音時間を挟む）なら**合格の見込み**。ただし余裕は 0.2 秒で、録音停止・撮影待ちの分は**実機確認**（m1.md §2）。続けて録ると**未達**。起動後の最初の 1 件は**未達**（STT 5.2〜8.4 秒） |
| 押下 → 録音開始 | ≤ 150ms | ホットキー・マイク・画面を通る経路なので**このハーネスでは測れない** | **実機確認（`docs/manual-tests/m1.md` §2 の計測表）** |
| アイドル時 CPU | ≤ 1% | Release のアプリ、モデル準備完了（起動 7 秒後）から 60 秒待って 60 秒間: CPU 時間 4.45 → 4.46 秒 = **0.02%**、`ps %cpu` は 60 回すべて 0.0 | 合格（トリアージ前・ウインドウなしの状態。§7 の要確認も参照） |
| 常駐メモリ（アイドル） | ≤ 4GB | d1 解放後（Whisper + 埋め込み）: ハーネス 591MB、アプリ 121MB（`footprint`） | 合格（ただし Core ML / ANE の重みはプロセスの footprint にほとんど出ない。§4） |
| 常駐メモリ（d1 常駐中 = トリアージ後 10 分） | （アイドルに含めるなら ≤ 4GB） | ハーネス 7.1GB（うち MLX キャッシュ 3.6GB）。キャッシュ上限 256MB なら 3.8GB | §8.1 の「アイドル」がこの期間を含むなら**未達**（上限を入れれば合格）。main の判断が要る |
| 常駐メモリ（トリアージ中） | ≤ 10GB | ピーク **7.22GB**（100ms ごとの phys_footprint の最大）、MLX アクティブのピーク 3.1GB | 合格 |

### 2.1 解放 → 保存（ハーネスのキャプチャ経路）

アプリの `AppCoordinator.save` と同じ並び: スクショの HEIC 符号化（detached、品質 0.85）と STT（語彙なし = アプリの既定）を並行 → スクショ書き込み →
音声（WAV を読んで）書き込み → `insert`。3 条件:

- **without_triage**: キャプチャ中はトリアージを走らせない（全件の後にまとめて流す）
- **with_triage_paced**: 次の件の前に、その音声の長さだけ待つ（話している = 録音している間に前の記録のトリアージが進む。実使用に近い）
- **with_triage**: 保存直後に enqueue し、間を空けずに次の件（直前の記録のトリアージが必ず裏で動いている。最悪に近い）

本計測（`20261011-015350-swiftpm-release.json`、秒）:

| 条件 | 周ごとの中央値 | 周ごとの p90 | 全体 p50 / p90 / 最大 | 開始時にトリアージが動いていた件数 |
|---|---|---|---|---|
| without_triage | 1.65 / 1.38 / 1.61 | 1.76 / 1.44 / 1.73 | 1.58 / **1.72** / 2.03 | 0 / 90 |
| with_triage_paced | 1.62 / 1.31 / 1.29 | 1.92 / 1.43 / 1.37 | 1.33 / **1.80** / 1.98 | 0 / 90 |
| with_triage | 3.78 / 3.10 / 2.49 | 5.12 / 3.74 / 2.63 | 3.03 / **4.38** / 5.47 | 87 / 90 |

内訳（全条件で同じ傾向）: STT が全体の 99.8% 以上。HEIC 符号化 p50 27〜35ms は STT と並行で、**STT の後に符号化を待った時間は全件 0ms**。
スクショ書き込み・音声書き込み・insert は合わせて p90 3〜4ms。→ §10 の目標は**全面的に STT（と ANE の取り合い）の問題**。

## 3. トリアージ

各ステップの所要時間は、`TriageQueue` に渡す本物の部品（`D1IntentClassifier`・`VisionSecretScanner`・`CoreMLEmbedder`）を薄い計時ラッパで包んで測った
（製品コードは変更していない）。本計測、秒:

| 条件 | guard p50 / p90 | intent（d1、2 問）p50 / p90 | index（融合埋め込み）p50 / p90 | 保存 → トリアージ完了 p50 / p90 |
|---|---|---|---|---|
| without_triage（単独） | 0.18 / 0.25 | 0.67 / 0.78 | 0.52 / 0.54 | （まとめて投入したので待ち時間込み。指標にしない） |
| with_triage_paced | 0.18 / 0.24 | 0.45 / 0.54 | 0.52 / 0.60 | 1.15 / 1.35 |
| with_triage（STT と競合） | 0.32 / 0.49 | 0.66 / 0.76 | 0.86 / 1.18 | 1.84 / 2.37 |

品質（本計測・1 回目・キャッシュ実験の 21 回の周・条件すべてで同値）:

| 指標 | e2e（STT の文字起こしで） | 比較（PoC・個別計測） |
|---|---|---|
| 意図 top-1（argmax） | **25/30** | MLX Swift 8bit dev 25/30（正解テキストで） |
| 意図（確信度 0.7 未満を未分類にした後） | 20/30 正解・6 件未分類・4 件誤り | — |
| 日時言及 | 27/30 | dev 28/30（正解テキストで） |
| ガード（記録経由。保存した HEIC を OCR） | 4/4 検出・誤検知 0（14 画面） | PoC 4/4・誤検知 0 |
| ガード（14 画面を直接。PNG / HEIC 品質 0.85 を読み戻し） | PNG 4/4・0 / HEIC 4/4・0、PNG 1 枚 p50 0.16 秒 | PoC 0.2 秒 |
| 検索（テキストクエリ 10、`embedQuery` → `store.search`、256 次元融合） | **R@3 0.933 / MRR 0.950** | 参照 融合 256 R@3 0.933 / MRR 0.950 |
| STT CER（語彙なし = アプリの既定設定） | **7.67%** | WhisperKit plain 7.72% |

## 4. メモリ（`phys_footprint`、MB）

本計測（`memory`）。RSS は参考値（MLX の Metal バッファ・Core ML を反映しない）。

| 時点 | phys_footprint | MLX アクティブ | MLX キャッシュ |
|---|---|---|---|
| 起動直後 | 8 | 0 | 0 |
| Whisper 読み込み後 | 41 | 0 | 0 |
| 埋め込み準備後（Whisper + 埋め込み） | 121 | 0 | 0 |
| d1 読み込み後（3 モデル同時） | 3,200 | 2,866 | 0 |
| 初回呼び出しの後 | 3,742 | 2,866 | 371 |
| d1 の数値テスト（52 件 × 2 問）の後 | 6,691 | 2,866 | **3,317** |
| キャプチャ・トリアージ全周の後 | 7,096 | 2,866 | **3,587** |
| トリアージ中のピーク（100ms 標本の最大） | **7,224** | 3,113（ピーク） | — |
| d1 解放後（Whisper + 埋め込み、2 秒後） | **591** | 0 | 0 |

- **Core ML（Whisper・埋め込み）の重みは ANE 側（`aned` など別プロセス）に置かれ、このプロセスの footprint にほとんど出ない**
  （Whisper 読み込み後 41MB、埋め込み後 121MB）。§8.1 の「3 つ同時常駐 5〜7GB」はプロセス内の値を想定した見積りなので、機械全体の消費はこの表より大きい。
  システム全体の値が要るなら Activity Monitor の「メモリ使用済み」の差などで別に測る必要がある
- **MLX のバッファキャッシュが上限なしに育つ**（d1 の推論 100 件ほどで 3.3GB、その後 3.6GB）。`D1IntentClassifier` は `unload()` で
  `Memory.clearCache()` を呼ぶが、推論中は `Memory.cacheLimit` を設定していない（`D1ModelPreparer` の変換時だけ 64MB にしている）。§7 問題 2・§8
- アプリ（(c)）の `phys_footprint_peak` は 2.8GB（d1 を読まない状態で）。埋め込み準備中の一時的なピークと見られる

## 5. d1 の数値一致（計画書 §6.1 残件「アプリ本体のビルドで d1 の数値テストを回す」）

`CCIntentTests/D1NumericsTests`（52 件の PyTorch MPS bf16 参照）を SwiftPM（`swift test -c release`）と Xcode
（`xcodebuild test -scheme ContextCaptureKit-Package -destination 'platform=macOS' -configuration Release -only-testing:CCIntentTests/D1NumericsTests`）で回した
（`*-d1-parity.json`）。xcodebuild はテストランナーへ環境変数をそのまま渡さないので、`TEST_RUNNER_CC_MODELS_DIR` / `TEST_RUNNER_CC_D1_RESULTS_OUT`
（`TEST_RUNNER_` 接頭辞を外して渡る）を使う。E2E（3 モデル同時）でも同じ指標を取った（`d1_numerics`）。

| ビルド | 意図 最大 \|Δp\| vs chain | 日時 最大 \|Δp\| | 意図 top-1 一致 | 正解 dev / 未見 | 1 件（2 問）p50（3 周の中央値） |
|---|---|---|---|---|---|
| SwiftPM Release | 0.04258 | 0.00924 | 51/52 | 25/30 / 21/22 | 0.70 秒（0.47 / 1.00 / 0.70） |
| Xcode Release | 0.04258 | 0.00924 | 51/52 | 25/30 / 21/22 | 0.77 秒（0.77 / 0.77 / 0.75） |
| E2E（3 モデル同時、SwiftPM Release） | 0.04258 | 0.00924 | 51/52 | 25/30 / 21/22 | 0.47 秒 |
| **SwiftPM と Xcode の差** | **0.0**（52 件 × 意図 5 値、全値が一致） | **0.0** | 52/52 同じ | — | — |

- **MLX の Metal カーネル（`mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`）は、SwiftPM のテスト・Xcode のテスト・アプリ本体（Release）の 3 つで
  sha256 が一致**（`282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f`、`*-metallib.json`）。この環境の SwiftPM は swift-build
  （`.build/out/Products`）で Xcode と同じ metal コンパイラを使うため。**アプリ本体の d1 の数値は上の表と同じ**と言える。
  ツールチェーンや MLX を上げたときは `scripts/e2e.sh` の metallib 比較で同一性を確かめ直せる
- 上限 0.05 に対する余裕は 0.0074（計画書の「余裕 0.007」と同じ）。調査書 §3.1 の MLX Swift 8bit（0.0386）より 0.004 大きいのは、
  Swift の `D1Tokenizer` でトークン化しているため（トークン列は 52/52 一致。以前からある差）
- 速さは周ごとに揺れる（SwiftPM の 2 周目 p90 2.9 秒など）。数値は 1 回目・2 回目・キャッシュ実験のすべてで同一

## 6. §8.1 の個別値との比較

| 処理 | §8.1 / 調査書の個別値 | e2e（3 モデル同時、本計測） | 所見 |
|---|---|---|---|
| 文字起こし | 1.3 秒 / CER 7.7%（WhisperKit p50 1.34 / p90 1.43） | トリアージなし p50 1.58 / p90 1.72、CER 7.67% | 精度は同じ。速さは 1.2 倍 |
| 意図・日時 | 0.75 秒 / 未見 95.5% | 0.45〜0.67 秒、未見 21/22（95.5%） | 一致（速い） |
| 秘密情報 | 0.2 秒 / 4/4・誤検知 0 | 0.18 秒（競合時 0.32）、4/4・誤検知 0（HEIC でも） | 一致 |
| 検索インデックス | 0.94 秒 / R@3 0.93 | 0.52 秒（競合時 0.86）、R@3 0.933 | 一致（速い） |
| メモリ | 3 つで 5〜7GB（見積り） | プロセス内 3.2GB（読み込み直後）〜7.2GB（ピーク、MLX キャッシュ込み） | 見積りの範囲。ANE 側は別 |
| 初回呼び出し | — | STT **5.2 秒**（1 回目 6.7〜8.4 秒）、d1 0.5 秒、埋め込み 0.5 秒、ガード 0.4 秒 | STT の初回が遅い（§7 問題 3）。ガード初回 24 秒（計画書 §6.0）は再現せず |

## 7. 考察・見つけた製品側の問題

### ボトルネック

1. **解放 → 保存は STT がすべて。** 符号化・保存は臨界経路に乗っていない（符号化待ち 0ms、保存 ≤ 5ms）
2. **ANE の取り合い。** Whisper（エンコーダ・デコーダとも `cpuAndNeuralEngine`）と、トリアージの index（埋め込みの画像塔・テキスト塔とも ANE）・
   guard（Vision OCR）が重なると、STT が 1.58 秒から 3.03 秒（p50）へほぼ倍になり、index も 0.52 → 0.86 秒に遅くなる。
   録音時間を挟む条件（paced）では前の記録のトリアージ（保存から完了まで p50 1.15 秒）が次の録音中に終わっており（開始時に動いていたのは 0/90 件）、影響が無い
3. 負荷だけでも STT は大きく落ちる（1 回目の高負荷時はトリアージなしで p90 3.76 秒）。基準機 M1 / 16GB では余裕 0.2 秒は残らない可能性が高い

### 見つけた製品側の問題

1. **アプリの Release ビルドが universal（x86_64 込み）で通らない。** `CCEmbedding` の `Float16` が x86_64 macOS で使えない
   （`EmbeddingGemma2Towers.swift:175,185`、`ImagePreprocessor.swift:229–242` で `'Float16' is unavailable in macOS`）。
   `xcodebuild -configuration Release` は既定で `ONLY_ACTIVE_ARCH=NO` なので落ちる（Debug は通る）。対処案: `app/project.yml` の Release に
   `ARCHS: arm64`（MLX も Apple Silicon 前提）。ハーネスは `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` で回避した
2. **MLX のバッファキャッシュに上限が無い**（§4）。d1 常駐中の footprint が 3.3〜3.6GB 余計に増える。上限 256MB の実験（§8）でピーク 7.2 → 4.1GB、
   d1 の速さは変わらず。対処案: `D1IntentClassifier.load()` で `Memory.cacheLimit` を設定する（例 256MB）
3. **アプリ起動後の最初の文字起こしが 5.2〜8.4 秒**（2 回目以降 1.6 秒前後）。`WhisperKitTranscriber.prepare()` は読み込みだけで推論しない
   （WhisperKit の `prewarm: false`、初回推論なし）。起動後の最初のキャプチャはトースト 2 秒を大きく超える。対処案: 読み込み後に短い無音
   （または合成音声）で 1 回推論しておく（埋め込みは `prepare()` で初回推論まで済ませている）
4. 意図の確信度しきい値 0.7 で 30 件中 6 件が未分類になる（top-1 なら 25/30 正解）。仕様どおりだが、M2 の「実発話 100 件で意図 ≥ 80%」を
   しきい値後の値で測るなら 20/30（67%）で届かない。どちらで測るかの定義が要る

### 要確認（このハーネスでは切り分けられなかった）

- 使わなかった時間帯の PID 9834（トリアージ 2 件の後・d1 常駐中、ウインドウ表示の有無は不明）は CPU 6% 前後（10 秒で CPU 時間 0.62 秒）で、
  そのとき WindowServer も 30〜50% だった。(c) の新規起動・トリアージ前・ウインドウなしの 0.02% と食い違う。「トリアージ後」「Inbox などのウインドウ表示中」
  「`--debug` の 5 秒ポーリング」のどれかが効いている可能性がある。実機で Activity Monitor を見て確かめたい

### 改善案

- **録音〜保存の間はトリアージの次のステップを始めない**（`TriageQueue` に一時停止を足し、`AppCoordinator` が録音開始で止めて保存で再開）。
  続けて録ったときの STT が 3.03 → 1.58 秒（p50）相当に戻る見込み
- Whisper の初回推論を起動時に済ませる（問題 3）、MLX のキャッシュ上限（問題 2）
- Whisper のデコーダを GPU（`textDecoderCompute: .cpuAndGPU`）へ移して ANE の取り合いを減らす案。d1（GPU）と取り合うので要計測
- 基準機（M1 / 16GB）で同じハーネスを回す（`scripts/e2e.sh` はそのまま動く）

## 8. MLX キャッシュ上限の実験（`20261011-023640-swiftpm-release-mlxcache256.json`）

`CC_E2E_MLX_CACHE_LIMIT_MB=256`（ハーネスが d1 読み込み前に `Memory.cacheLimit` を設定。**製品の挙動とは異なる**）で 1 周 × 3 条件（02:41〜02:48、load 2.8〜4.3）。

| 指標 | 上限なし（本計測） | 上限 256MB |
|---|---|---|
| MLX キャッシュ（全周の後） | 3,587MB | 269MB |
| phys_footprint（d1 数値テスト後 / 全周の後） | 6,691 / 7,096MB | 3,647 / 3,774MB |
| トリアージ中のピーク | 7,224MB | **4,084MB** |
| d1 1 件（2 問）p50（E2E 内 52 件） | 0.47 秒 | 0.48 秒 |
| intent ステップ p50（without / paced / with） | 0.67 / 0.45 / 0.66 秒 | 0.42 / 0.44 / 0.72 秒 |
| d1 の数値・正解数 | 0.04258・25/30・21/22 | 同一 |

## 9. 再現手順

```zsh
# 3 モデル（読み取りのみ）
export CC_MODELS_DIR=/Users/yoshio/works/60-misc/memo-collector/spikes/dev-models
# 全部: (a) E2ETests → (b) d1 の SwiftPM / Xcode → (c) アプリのアイドル CPU → metallib の sha256（約 45 分）
scripts/e2e.sh
# 一部だけ
CC_E2E_STEPS="b" scripts/e2e.sh
# 動作確認（1 周 3 件）
CC_E2E_ROUNDS=1 CC_E2E_LIMIT=3 CC_E2E_STEPS=a scripts/e2e.sh
# MLX キャッシュ上限の実験
CC_E2E_STEPS=a CC_E2E_ROUNDS=1 CC_E2E_MLX_CACHE_LIMIT_MB=256 CC_E2E_CONFIG=swiftpm-release-mlxcache256 scripts/e2e.sh
```

- 各段の前に 1 分平均の load average が `CC_E2E_MAX_LOAD`（既定 3.0）未満になるのを最大 `CC_E2E_LOAD_WAIT`（既定 600）秒待ち、`uptime` を出す。
  下がらなければそのまま測る（JSON に load average と上位プロセスが残る）。**計測前に他の重い処理（ビルド、他の ContextCapture、ANE の初回コンパイル）を止めること**
- (a) の E2ETests は `CC_RUN_E2E=1` のときだけ走る（通常の `swift test` では skip）。xctest バイナリが変わると埋め込みの ANE 初回コンパイル（1.5〜3 分）が入る
  （`model_loads.embedding_prepare_report` に出る。計測には入らない）
- (c) は Release のアプリを `open -n -a … --env CC_DATA_DIR=<一時> --env CC_MODELS_DIR=… --args -ContextCapture.settings.v1 <hex>` で起動する。
  オンボーディングは**引数ドメイン**で設定 `{"onboardingCompleted":true}` を渡して飛ばす（ユーザーの defaults に書かない。オンボーディングのモデル準備が
  manifest を書くのも避けられる）。起動後に `ps eww` とアプリのログ（`data: <一時>`）の両方で `CC_DATA_DIR` が効いていることを確かめ（本計測は両方 OK）、
  確かめられなければ計測をやめる。終了は起動したプロセスの PID への SIGTERM だけ（Apple Event は送らない）。`ps %cpu` は減衰平均なので、
  CPU 時間の差 / 経過時間を正とする
- 統合ログは `/usr/bin/log`（zsh の `log` は組み込みコマンド）
- 結果: `docs/e2e/results/<stamp>-swiftpm-release.json`（(a)）、`-d1-parity.json`（(b)）、`-app-idle.json`（(c)）、`-metallib.json`

## 付録: 結果ファイル

| ファイル | 内容 | 扱い |
|---|---|---|
| **`20261011-015350-*.json`** | **本計測**（(a)(b)(c)・metallib） | 本報告の値 |
| `20261011-023640-swiftpm-release-mlxcache256.json` | MLX キャッシュ上限 256MB の実験（1 周） | §8 |
| `20261011-004409-*.json` | 1 回目の全体実行 | **使わない**（§1.1。高負荷・PID 9834 並行）。負荷時の参考のみ |
| `20261010-235856-d1-parity.json` | (b) のみの試走（SwiftPM / Xcode 差 0.0） | 参考（load 2.9） |
| `20261011-003605-app-idle.json` | (c) のみの試走（CPU 0.00%。`cpu_time_start_s` 等の欄が入る前の版） | 参考（PID 9834 の起動前） |
