# 外部プロジェクト調査: FluidUse と embeddinggemma-2-coreml

- 対象: [FluidInference/FluidUse](https://github.com/FluidInference/FluidUse)（commit `e974b38`、2026-10-09）と [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)（revision `3f978dd`、2026-10-09）
- 関係する計画: [MVP 実装計画](../plans/mvp-implementation.md) の CCEmbedding / CCCapture / CCMCP / CCModels、[PRD](../prd/PRD.md) §5・§8.1・§9、先行調査 [runtime-coreml-mlx.md](runtime-coreml-mlx.md)
- 実施: 2026-10-10（UTC 06:55〜08:17。各計測の開始時刻は結果 JSON の `started_at`）
- 環境: Apple M3 / 24GB、macOS 27、Xcode 27 / Swift 6.4、coremltools 9.0（Python 3.12）。**GPU と ANE は実装チームと共有**しており、GPU の計測は時刻によって 2 倍近く揺れた（下記 3.3）。レイテンシは各条件 3 周の「周ごとの中央値」の中央値
- 成果物はすべて `spikes/fluid/` 配下（モデル・vendor・.build・.venv は `.gitignore` で除外）

## 1. 結論

| 対象 | 判定 | 根拠（実測） |
|---|---|---|
| **embeddinggemma-2-coreml（テキスト）** | **採用（MLX Swift 手書き移植を置き換える）** | PyTorch 参照とのコサイン最小 0.9997（50 文）、Recall@3 / MRR は 256 次元で参照と完全一致。Swift（FluidUse の実装）で ANE 上 **1 件 5.0〜5.3ms**（MLX Swift 13ms）、ピーク 0.30GB（同 0.59GB）、トークナイザ 50/50 一致 |
| **embeddinggemma-2-coreml（画像・融合）** | **採用** | Swift + Core ML だけで画像・融合が動いた（前処理は今回 Swift で書いた約 300 行）。コサイン最小 画像 0.9987・融合 0.9994、**融合 256 の R@3 0.933 / MRR 0.950 は参照と同値**。融合 1 件 0.94 秒（ANE、280 トークン）。計画の受け入れ条件（参照コサイン ≥ 0.995、融合 256 の R@3 ≥ 0.9）を満たす |
| 画像トークン予算 70（参考） | 要判断（有力） | 融合 1 件 **0.15 秒**（280 の 1/6）。小標本（画面 14・記録 30）では検索指標が下がらない（融合 256 R@3 0.933 / MRR 1.000）。ただし参照（280）とは別物のベクトルになる |
| **FluidUse（ライブラリ依存として）** | **不採用（コードを参考・一部を写す）** | 3 週間前に作られた 1 人開発のリポジトリで、EmbeddingGemma 2 を含むリリースタグが無い（v0.3.0 には未収録）。依存に FluidAudio が付き、無関係な管理クラスが多数入る。画像は未実装 |
| FluidUse（CCCapture の参考） | 部分的に参考 | ScreenCaptureKit・URL 取得・OCR は無い。参考になるのは AX の読み方 3 点（Chromium / Electron の AX ツリーを有効にする属性、選択テキストの取り方、予算付きの木の走査）。手元では**アクセシビリティ権限が無く AX 読み取りは未検証** |
| FluidUse（CCMCP の参考） | 不採用 | MCP の実装は無い（`mcp` の出現は demo のラベル文字列 1 か所だけ） |

**最大の論点への答え**: 画像・融合埋め込みは Core ML 版で賄える。計画上の「画像塔の Swift 移植 +4〜6 人日」は「画像前処理と融合列の組み立て（Swift で約 300 行、動作確認済み）」に置き換わり、CCEmbedding 全体の見積りは **MLX 経路 6〜9 人日 → Core ML 経路 3〜4 人日**（差し引き 3〜5 人日の削減）。副次効果として埋め込みが GPU から ANE に移り、d1-3B（MLX、GPU）・WhisperKit と GPU を取り合わなくなる。

主なリスク: (1) **ANE 向けの初回コンパイルが長い**（テキスト 7 関数で 111〜134 秒、画像 280 で 47〜62 秒。キャッシュは実行バイナリ単位で、同じ中身のバイナリを別名にコピーしただけで再コンパイルされた。2 回目以降は数秒〜20 秒）。(2) 第三者による変換で、HF リポジトリは更新が続いている（revision 固定・sha256・参照との一致テストが必須）。(3) 画像塔は M3 では ANE / GPU とも 1 枚 0.7 秒前後で、README の M5 Pro の値（GPU 64〜177ms）より大幅に遅い。

## 2. 2 つのプロジェクトの概要

### 2.1 FluidUse

| 項目 | 内容 |
|---|---|
| 何をするか | 「Apple silicon 上のローカル computer use」。他アプリのフォームを Accessibility API で読み、小さなオンデバイスモデル（CUA-S1-FORMS 等）で各欄に入れる値を決め、実際に入力する。加えて、FluidInference が Core ML 化した各種小型モデル（laya、GLiClass、GLiNER 2.5、Kev、Clef-vision、Intern-Decision、Decision 2.0、Vela 2.0、Short-reply、SigLIP 2、**EmbeddingGemma 2**）の Swift ランタイムとデモを 1 パッケージに同居させている |
| ライセンス | Apache-2.0（LICENSE 同梱。CUA-S1-FORMS は MIT と README に記載） |
| 成熟度 | 作成 2026-09-21、最終 push 2026-10-10。コミット 71 件はすべて 1 人（Alex-Wengg）。リリース v0.1.0〜v0.3.0（最新 v0.3.0 は 2026-09-25 で、EmbeddingGemma 2 は**未収録**。使うなら commit 固定になる）。Star 294、open issue 9 |
| 構成 | SwiftPM（tools 6.0、macOS 14+）。ライブラリ `FluidUse` 1 個 + 実行ターゲット約 35 個（demo / check）。Swift 約 1.6MB、Python・JS は補助 |
| 依存 | `FluidAudio`（from 0.15.8。今回の解決は 0.17.7）。ただし**ライブラリ本体のソースは FluidAudio を import していない**（使っているのは `FluidUseDemo` だけ）。それでもライブラリの依存として宣言されているので、取り込むと FluidAudio も入る |
| 同梱リソース | `Resources/published-coreml-worker.py`（他モデル用の Python 常駐プロセス。`Process` で起動される）、`cua-observer.js`（WKWebView 用） |

画面コンテキスト取得の観点で読んだ結果（`Sources/FluidUse/AccessibilityFormDriver.swift`、`Sources/ShortReplyDemo/SelectionReader.swift`、`Sources/BookmarkSort/XTimelineReader.swift`）:

| PRD の項目 | FluidUse にあるか | 参考になる点 |
|---|---|---|
| 前面アプリ・バンドル ID | `NSWorkspace.shared.frontmostApplication`（一般的な API そのまま） | 無し |
| ウインドウタイトル | `kAXFocusedWindowAttribute` → `kAXTitleAttribute` | 無し（計画どおり） |
| URL（Safari / Chrome / Arc / Edge） | **無い**（AppleScript も `AXURL` も使っていない） | 無し |
| スクショ（ScreenCaptureKit） | **無い** | 無し |
| OCR・画面理解 | **無い**（Vision OCR 不使用）。画像判断は Clef-vision（0.9B、GPU）で、PRD の CCGuard とは用途が違う | 無し |
| 選択テキスト | `kAXSelectedTextAttribute`、取れなければ ⌘C を送ってペーストボードを読み、元に戻す | P1 の「選択テキスト」を足すなら手順の参考になる。ただしペーストボード経路は文字列型しか復元せず、他アプリにキー入力を送るので本アプリの方針（読むだけ）には合わない |
| Chromium / Electron の AX ツリー | アプリ要素に `AXManualAccessibility` と `AXEnhancedUserInterface` を true で書き込み、Web 内容の AX ツリーを作らせる | **P1 の「VS Code のファイルパスと行」に効く可能性がある**（VS Code は Electron）。ただし対象アプリの属性を書き換える副作用があり、本調査では未検証 |
| AX ツリーの走査 | 予算（要素数・深さの上限）付きで子要素をたどり、`AXStaticText` を集める | 走査の打ち切り方の参考になる |
| Finder の選択ファイル・Terminal の cwd | 無い | 無し |

### 2.2 embeddinggemma-2-coreml

| 項目 | 内容（README・config.json・モデル仕様を読んで確認） |
|---|---|
| 元モデル | `google/embeddinggemma-2`。重みは元のまま fp16 で格納（トークン表のみ元の bf16）。出力は sentence-transformers と同じ 768 次元・L2 正規化。Matryoshka で 512/256/128 に切って再正規化できる |
| ライセンス | モデルカード `license: apache-2.0`（元モデルと同じ）。リポジトリは FluidInference（Google 公式ではない） |
| モダリティ | **テキスト・画像・音声の 3 塔すべて**（動画は画像塔をフレームに使う） |
| テキスト | `EmbeddingGemma2Text.mlpackage`（ML Program、fp16、271MB）。**固定長の関数 7 個が重みを共有**: `embed_32/48/64/128/256/512`（入力 `inputs_embeds` [1,S,512] fp16 と `attention_mask` [1,S]）と `pack_256`（最大 8 文を 1 系列に詰める）。512 トークン超は切り詰め（≤512 ではスライディング窓が全体を覆うのでマスクはパディングだけで足りる）。トークン表 `embeddings.bf16`（262,144×512、256MB）は**モデル外**で、呼び出し側が行を引いて √512 倍して渡す |
| 画像 | `EmbeddingGemma2Vision.mlpackage`（Gemma 4 ViT 16 層 + 3×3 プーリング + 射影、fp16、292MB）。関数 `vision_70/140/280`（パッチ 630/1260/2520）。入力はパッチ・位置・位置埋め込み（`position_embeddings.f16` から呼び出し側が足す）・有効フラグ・プーリング行列。出力は画像トークン [1,T,512] で、`<bos> <\|image> トークン <image\|> <eos>` をテキストモデルに通して埋め込みにする |
| 音声 | `EmbeddingGemma2Audio.mlpackage`（USM conformer 12 層、log-mel をグラフ内で計算、fp16、561MB）。10 秒窓 → 250 トークン → テキストモデル。README は GPU 推奨 |
| 精度・量子化 | すべて fp16。量子化版は無い。モデルカードが fp16 を禁じている点は、RMSNorm を行ごとの最大絶対値で割ってから二乗する改変で回避したと README にある（素の fp16 だとコサイン 0.95） |
| 計算ユニット | テキストは ANE 向け（README: 3,862/3,862 op が ANE に載る。今回は配置の確認はしていない）。画像・音声は README が GPU 推奨 |
| トークナイザ | 元の Gemma `tokenizer.json`（そのまま）。Swift 実装は FluidUse の `EmbeddingGemma2Tokenizer`（byte-fallback BPE の移植） |
| Swift から使う手段 | 素の Core ML（multifunction のため macOS 15+）。FluidUse の `EmbeddingGemma2Manager` がテキストと音声を実装（**画像は未実装**）。FluidAudio 経由ではない |
| サイズ | 合計 1.4GB（音声を除くと 0.85GB: テキスト 271MB + トークン表 256MB + トークナイザ 31MB + 画像 292MB + 位置表 3MB） |
| 版の変化 | FluidUse が固定しているテキストの revision `70fcf18` と今回の `3f978dd` で、テキストの mlpackage・トークン表・トークナイザの sha256 は一致（`config.json` だけ画像の節が増えて変化） |

## 3. 実測

評価は先行調査と同じ: PyTorch 参照 `spikes/runtime/data/embed_reference.npz`（sentence-transformers 6.1、MPS bf16）、`poc/fixtures/dataset.json`（注釈 30・画面 14・text_queries 10・image_queries 10）、指標は `exp04_embedding.py` と同じ `recall_mrr`。文書は `title: {window_title} | text: {注釈}\n{メタ}`、クエリは `task: search result | query: `、融合は `title: … | text: … <|image|>` + スクショ。

経路は 2 つ用意した。

- **Python（coremltools）**: 入力を sentence-transformers の前処理結果そのもの（`data/st_inputs.npz`）にし、Core ML の数値だけを切り出して比べる（`scripts/coreml_eval.py`）
- **Swift**: 製品と同じ形。テキストは FluidUse の `EmbeddingGemma2Manager` を SwiftPM パス依存で呼ぶ（`eg2-bench`）。画像・融合は今回書いた前処理 + Core ML 直呼び（`eg2-image`）。トークナイザも画像の縮小も Swift 側の実装

### 3.1 数値一致と検索指標

| 経路 | コサイン最小（平均）文書 / クエリ / 画像検索用クエリ | 画像 | 融合 | R@3 / MRR 768 文字→記録 | 256 文字→記録 | **融合 256** | 融合 768 | 画像のみ 768 | 画像のみ 256 |
|---|---|---|---|---|---|---|---|---|---|
| PyTorch 参照 | — | — | — | 0.883 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.883 / 0.900 | 0.800 / 0.731 | 0.650 / 0.712 |
| Python Core ML テキスト ANE・画像 GPU | 0.99973 (0.99992) / 0.99993 / 0.99990 | 0.9985 (0.9996) | 0.9995 (0.9998) | 0.933 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.733 | 0.650 / 0.712 |
| Python Core ML テキスト・画像とも ANE | 同上 | 0.9988 | 0.9993 | 同上 | 同上 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.737 | 0.650 / 0.712 |
| Python Core ML GPU / ALL | 0.99989 / 0.99994 / 0.99993 | 0.9984〜0.9988 | 0.9993〜0.9995 | 0.933 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.733〜0.737 | 0.650 / 0.712 |
| Python Core ML CPU のみ | 0.99966 / 0.99991 / 0.99988 | 0.9967 | 0.9992 | 0.933 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.729 | — |
| **Swift（FluidUse テキスト ANE + 自作画像前処理、画像 ANE）** | 0.99973 / 0.99993 / 0.99990（トークン 50/50 一致） | **0.9987 (0.9995)** | **0.9994 (0.9997)** | 0.933 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.733 | 0.650 / 0.712 |
| Swift 同上、画像 GPU | 同上 | 0.9982 | 0.9995 | 同上 | 同上 | **0.933 / 0.950** | 0.883 / 0.950 | 0.800 / 0.733 | — |
| Swift、縮小を CoreGraphics `.high` にした場合（比較用） | 同上 | **0.9938** | 0.9986 | 同上 | 同上 | 0.933 / 0.950 | 0.883 / 0.900 | 0.800 / 0.729 | — |

- 768 次元の文字→記録で R@3 が参照 0.883 → 0.933 に上がるのは、全経路で共通（コサイン 0.9997 以上）。ランキング下位の入れ替わりで、MLX でも融合 768 の MRR に同種のずれ（0.900 → 0.950）が出ていた。256 次元（PRD の索引）は全指標が参照と一致。
- **画像の縮小は HF と同じ bicubic（PIL / torchvision antialias と同じ分離型、a=−0.5、縮小時はカーネル幅を拡大、各パス後に uint8 へ丸め）にする必要がある。** CoreGraphics の `.high` 補間では画像単体のコサインが 0.9938 まで落ち、計画の受け入れ条件 0.995 を割った。bicubic を Swift で書いた版（`resizeBicubic`、約 50 行）で 0.9987 に戻った。
- 融合列のトークン列は Swift で組み立てたものが HF と 30/30 一致（`"<|image|>"` の直前の空白を残し、`<|image>` + ソフトトークン × n + `<image|>` + `<eos>` を足す）。ソフトトークン数（縮小後のサイズから計算）も 14/14 一致。

### 3.2 レイテンシ（1 件、3 周の中央値。括弧は周ごと）

| 経路・計算ユニット | 計測開始（UTC） | 文書 | クエリ | 画像塔のみ | 画像 1 枚の埋め込み | 融合 1 件 |
|---|---|---|---|---|---|---|
| **Swift テキスト ANE（FluidUse）** | 07:31:53 | **5.3ms** (5.1/5.3/5.6) | **5.0ms** (5.0/4.9/5.0) | — | — | — |
| Swift テキスト ANE、50 件をまとめて（`pack_256` + 並列 8） | 07:31:53 | 1 件あたり 3.3ms | | | | |
| Swift テキスト ALL | 07:34:44 | 16ms | 13ms | — | — | — |
| Swift テキスト GPU | 07:32:55 | 36ms (21/36/43) | 27ms (27/27/17) | — | — | — |
| **Swift 画像 ANE + テキスト ANE（280）** | 07:56:08 | — | — | 0.73 秒 | 1.01 秒 (1.10/1.01/0.85) | **0.94 秒** (0.95/0.94/0.92) |
| Swift 画像 GPU + テキスト ANE（280） | 07:59:29 | — | — | 0.81〜1.02 秒 | 1.50 秒 | 1.07 秒 (1.31/0.91/1.07) |
| Python 画像 GPU + テキスト ANE（280） | 07:45:36 | 9.3ms | 7.6ms | 0.77 秒 | 0.83 秒 | 0.84 秒 (0.82/0.84/1.33) |
| Python 画像・テキストとも ANE（280） | 07:22:04 | 13ms | 7.8ms | 0.79 秒 | 0.81 秒 | 0.69 秒 (0.80/0.68/0.69) |
| Python GPU / GPU（280） | 07:02:04 | 16ms | 13ms | 0.48 秒 | 0.65 秒 | 0.91 秒 (1.31/0.91/0.89) |
| Python GPU / GPU（280、2 回目） | 07:50:34 | 80ms | 61ms | 1.12 秒 | 1.33 秒 | 1.39 秒 |
| Python ALL / ALL（280） | 07:17:51 | 29ms | 37ms | 0.78 秒 | 0.81 秒 | 0.83 秒 |
| Python CPU のみ（280） | 07:25:57 | 28ms | 16ms | 1.10 秒 | 1.13 秒 | 1.13 秒 |

- Swift の画像 1 枚・融合 1 件の内訳は、前処理（縮小・パッチ化）0.12〜0.18 秒 + 画像塔 0.73 秒 + テキスト塔 0.01〜0.03 秒。前処理は最適化していない素朴な Double ループで、Accelerate（vDSP）化で縮められる見込み（未実施）。
- **GPU の値は時刻で 2〜6 倍揺れた**（同じ Python GPU / GPU でもテキストが 16ms → 80ms）。実装チームと GPU を共有している影響と見ている（切り分けは未実施）。ANE の値は周ごと・回ごとに安定していた。
- 07:05〜07:16 は Swift の依存ビルド（FluidAudio 等、656 秒）と重なっており、その間の Python の計測（`coreml_ne_gpu*.json`、`coreml_all_all.json`）は CPU 競合を含む。表には重ならなかった回を優先して載せた。

### 3.3 ロード時間・メモリ・ディスク

| 経路 | 初回ロード（ANE 向けコンパイル込み） | 2 回目以降 | メモリ |
|---|---|---|---|
| Swift テキスト ANE（7 関数、FluidUse） | **134 秒** | **5.7 秒** | phys_footprint ロード後 59〜81MB、**ピーク 0.30GB** |
| Swift テキスト GPU / ALL | 32 秒 / 93 秒 | 未計測 | ピーク 0.86GB / 0.32GB |
| Swift 画像 ANE（`vision_280`）+ テキスト 3 関数 ANE | 画像 47〜62 秒（予算ごと） | 画像 0.5〜0.9 秒 + テキスト 2.5〜2.9 秒 | **ピーク 0.20GB**（autoreleasepool あり） |
| Swift 画像 GPU + テキスト ANE | 画像 1.9 秒 | 画像 0.9〜1.2 秒 | ピーク 0.45GB |
| Python テキスト ANE（6 関数）+ 画像 GPU | テキスト 111 秒 | テキスト 16.7 秒 / 37.7 秒 | RSS 0.59〜0.68GB、peak footprint 0.51〜0.72GB |
| Python テキスト・画像 ANE | 画像 47 秒 | — | peak footprint 0.32GB |
| Python GPU / GPU | 25 秒（テキスト） | 8.4 秒 | RSS 2.4GB（ロード後）、USS 0.59GB |

- **ANE 向けコンパイルのキャッシュは実行バイナリ単位**: Python で ANE コンパイル済みでも Swift の初回は 134 秒かかった。切り分けとして、ロード済みの `eg2-bench` をもう一度動かすと 23 秒、**同じバイナリを別名（`/tmp` へ `cp`）にして動かすと 292 秒**（08:22〜08:27 UTC、7 関数。`results/swift_text_CPU_AND_NE_3rd.json` と `_copied_binary.json`）で再コンパイルされた。したがって**温めは製品アプリのプロセス内で行う必要があり、`cc-models` など別の実行ファイルで温めても効かない**。開発中はビルドのたびにバイナリが変わるので、毎回 2〜5 分の再コンパイルが起きうる（同じパスでの上書き＝アプリ更新や再ビルドで消えるかは未検証）。2 回目以降のロード時間も 5.7〜23 秒と揺れた。
- **Swift で Core ML を回すループは `autoreleasepool` で囲む必要がある。** 囲まなかった版では画像 44 件の処理でフットプリントが 1.9〜2.2GB まで積み上がった（`swift_image_ne_ne.json` 等）。囲んだ版は 0.20GB。
- ディスク: テキスト 271MB + トークン表 256MB + トークナイザ 31MB + 画像 292MB + 位置表 3MB = **0.85GB**（音声 561MB は不要）。`.mlmodelc` はパッケージと同じ大きさなので、コンパイル後にパッケージを消さないと 2 倍になる。

### 3.4 画像トークン予算（70 / 140 / 280）

README は予算を下げると速いとしている。参照（280）とは入力が異なるので「一致」ではなく検索指標で比べた（Swift、テキスト ANE、bicubic）。

| 予算 | 画像塔 | 融合 1 件（画像 ANE） | 融合 1 件（画像 GPU） | 融合 256 R@3 / MRR | 融合 768 | 画像のみ 768 | 画像のみ 256 | 参照（PyTorch・280）とのコサイン（融合、平均） |
|---|---|---|---|---|---|---|---|---|
| 280（参照と同じ） | 0.73 秒 | 0.94 秒 | 1.07 秒 | 0.933 / 0.950 | 0.883 / 0.950 | 0.800 / 0.733 | 0.650 / 0.712 | 0.9997 |
| 140 | 0.24〜0.37 秒 | 0.38 秒 (0.65/0.38/0.35) | 0.63 秒 | 0.933 / 0.950 | 0.883 / 0.950 | 0.850 / 0.870 | 0.850 / 0.867 | 0.975 |
| **70** | **0.08 秒** | **0.15 秒** (0.15/0.16/0.15) | 0.34 秒 | 0.933 / **1.000** | 0.883 / 1.000 | 0.900 / 0.761 | 0.900 / 0.810 | 0.955 |

- 画面 14 枚・記録 30 件の小標本なので、「70 でも劣化しない」とまでは言えない（逆に良く見える差も 1〜2 件の入れ替わり）。言えるのは「この評価セットでは下がらなかった」まで。
- 予算を変えるとベクトル空間の中身が変わるので、索引は 1 つの予算に揃える必要がある（途中で変えたら再索引）。

### 3.5 MLX（先行調査）との比較

| 項目 | MLX Swift 手書き移植（先行調査） | MLX Python bf16（先行調査） | **Core ML（今回、Swift、ANE）** |
|---|---|---|---|
| テキストのコサイン最小 | 0.9981 | 0.9998 | **0.9997** |
| 画像 / 融合のコサイン最小 | 未移植 | 0.9989 / 0.9995 | **0.9987 / 0.9994** |
| 融合 256 の R@3 / MRR | 未移植 | 0.933 / 0.950 | **0.933 / 0.950** |
| テキスト 1 件 | 13ms | 13ms / 8.7ms | **5.0〜5.3ms**（まとめると 3.3ms） |
| 画像 1 枚 / 融合 1 件 | 未移植 | 0.55 / 0.56 秒 | 1.01 / 0.94 秒（280）、0.16 / 0.15 秒（70） |
| メモリ | ピーク 0.59GB（テキストのみ） | 1.5GB / ピーク 2.3GB | **ピーク 0.30GB（テキスト 7 関数）/ 0.20GB（画像 + テキスト 3 関数）** |
| ディスク | 0.55GB（テキスト塔） | 1.4GB | 0.56GB（テキスト）/ 0.85GB（テキスト + 画像） |
| 使う演算器 | GPU | GPU | **ANE**（d1・Whisper と GPU を取り合わない） |
| 512 トークン超 | sliding mask 未実装 | 対応 | 切り詰め（README: 512 で上限にしても測定差なし。今回のデータは最長 86 トークン） |
| 初回の準備 | 変換（抽出）が必要 | 変換不要 | ANE コンパイル 2〜5 分（実行バイナリごと。アプリ内で温める必要あり） |
| 製品化に残る Swift 作業 | テキスト: sliding mask・バッチ / 画像: 視覚塔 + プロセッサの移植（+4〜6 人日） | （Python なので不採用） | テキスト: FluidUse の実装を写す / 画像: 今回の前処理（約 300 行）の製品化 |

融合 1 件は Core ML（280、M3）の方が MLX Python より遅い（0.94 秒 vs 0.56 秒）。PRD §8.1 の検索インデックスは非同期で「0.6〜0.8 秒」を想定しており、280 のままだとやや超える。予算 70 にすれば 0.15 秒になる（品質の確認は上記の小標本のみ）。

## 4. 設計への適用提案

### 4.1 CCEmbedding: **Core ML 版を採用（MLX Swift 移植を置き換え）**

- 方式: `FluidInference/embeddinggemma-2-coreml` を **revision 固定**（例: `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4`）で使う。テキストは `embed_S`（とまとめ処理の `pack_256`）を ANE、画像は `vision_280` を ANE。**これは速度ではなく GPU 競合を避けるための選択**: 競合の少なかった回の GPU は画像塔 0.48 秒で ANE（0.73〜0.79 秒）より速かったが、GPU は d1-3B・WhisperKit と共有になり、今回も時刻によって 2 倍以上揺れた。ANE の初回コンパイル（画像 47〜62 秒）を避けたいなら GPU にする手もある（初回ロード 1〜2 秒）。256 次元は先頭 256 を切って再正規化（現行の `Embedding` 契約のまま）
- コード: FluidUse を**依存にはしない**。`EmbeddingGemma2Manager` / `EmbeddingGemma2Tokenizer` / `EmbeddingGemma2Types`（Apache-2.0）を CCEmbedding に写し、ライセンス表記を残す。画像・融合は `spikes/fluid/swift/FluidBench/Sources/eg2-image/main.swift` の前処理（bicubic 縮小・パッチ化・位置埋め込み・プーリング行列・融合列）を製品コードにする
- 受け入れ条件（計画の値のまま満たせる）: 参照コサイン ≥ 0.995（実測 画像 0.9987・融合 0.9994・テキスト 0.9997）、融合 256 の R@3 ≥ 0.9（実測 0.933）。加えて「融合列のトークン列が HF と一致」「ソフトトークン数が一致」をテストに入れる
- 工数: テキスト（写して契約に合わせる・テスト）1 日、画像・融合（前処理の Accelerate 化、ScreenCaptureKit の色空間 → sRGB の扱い、テスト）1.5〜2 日、CCModels 側の取得・検証・コンパイル・ANE の温め 0.5〜1 日。**計 3〜4 人日**（MLX 経路はテキスト 2〜3 + 画像 4〜6 = 6〜9 人日）
- 依存: 埋め込みのためには mlx-swift は不要になる（d1-3B が使うので Package.swift からは消えない）。swift-transformers のトークナイザも埋め込みには使わない
- 決めること（main）: 画像の予算を 280（参照と一致・0.94 秒）にするか 70（0.15 秒・小標本では指標同等）にするか。Wave 3 で記録を増やして再評価してから決めるのが安全
- リスクと対策
  - ANE の初回コンパイル 2〜5 分（実行バイナリ単位でキャッシュ）→ **アプリ本体のプロセス内**で、初回起動時（オンボーディングのモデル準備の最後）にバックグラウンドでロードして温め、進捗を出す。`cc-models` で温めても効かない。キャッシュが消える条件（OS / アプリ更新）は未検証なので、ロードが遅いときに UI を固めない作り（非同期のまま、未準備の間は索引をキューに積む）にする。開発中のテストは毎ビルド再コンパイルになりうるので、モデル付きテストは ANE ではなく CPU_AND_GPU で回す選択肢も持つ
  - 第三者の変換・リポジトリが更新中 → revision と sha256 を `manifest.json` に固定（FluidUse の `EmbeddingGemma2ModelStore` は `EMBEDDINGGEMMA2_MODEL_DIR` 指定時に検証を飛ばすので、その経路は写さない）。参照 npz との一致テストを CI 相当（`scripts/check.sh` のモデル付きテスト）に入れる
  - 画像の縮小の実装差でコサインが落ちる（CoreGraphics `.high` で 0.9938）→ bicubic を自前実装し、テストで縛る
  - Core ML ループのメモリ積み上がり → 1 件ごとに `autoreleasepool`
  - M3 では画像塔が 0.7 秒（README の M5 Pro より遅い）→ 非同期キューで処理。予算を下げる選択肢を残す
  - 512 トークン超は切り詰め → 注釈 + メタは今回最長 86 トークンで問題にならない

### 4.2 CCCapture: **計画どおり（FluidUse は参考のみ）**

- F-02〜F-04（ホットキー・ScreenCaptureKit・アプリ名 / タイトル / URL）に流用できる部品は無い。ScreenCaptureKit も URL 取得も FluidUse には無い
- P1 の「VS Code のファイルパスと行」には、FluidUse がやっている `AXManualAccessibility = true`（Electron / Chromium に AX ツリーを作らせる）が手がかりになる。ただし対象アプリの属性を書き換える副作用があるので、P1 で検証してから採る（MVP には入れない）
- 選択テキストを取るなら `kAXSelectedTextAttribute` までにとどめ、⌘C を送る経路（FluidUse の `SelectionReader`）は採らない（他アプリへの入力・ペーストボードの改変になる）
- 工数への影響なし

### 4.3 CCMCP: **影響なし**

FluidUse に MCP の実装は無い。計画どおり MCP swift-sdk で書く。

### 4.4 CCModels / cc-models

- `cc-models prepare embedding` を「HF から revision 固定で 9 ファイル（音声を除く）を取得 → sha256 検証 → `.mlmodelc` にコンパイル → パッケージ削除」に変える（ANE の温めは別バイナリでは効かないので、アプリ側の CCTriage / CCEmbedding の初回ロードで行う）。抽出・変換（先行調査の `embed_extract_text.py`）は不要になる
- 配置は `Models/embeddinggemma-2/`（計画どおり）。`manifest.json` に revision・各ファイルの sha256・予算を書く

## 5. 再現手順

```zsh
cd spikes/fluid

# 0) 取得物（信頼しないデータとして vendor/ と models/ に置く。どちらも git 管理外）
git clone https://github.com/FluidInference/FluidUse vendor/FluidUse && git -C vendor/FluidUse checkout e974b3841aaa438cd4d35dcbc5ba385b4c720643
./scripts/download_eg2.sh            # revision 3f978dd を models/embeddinggemma-2-coreml/ へ（1.4GB）

# 1) 参照と同じ前処理の入力を書き出す（poc/.venv を参照実行のみ。forward はしない）
HF_HUB_OFFLINE=1 ../../poc/.venv/bin/python -I scripts/dump_st_inputs.py ../.. data/st_inputs.npz

# 2) Python（coremltools）: 計算ユニット別。2 つ目の引数のディレクトリに .mlmodelc を作って再利用する
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python "coremltools==9.0" numpy psutil
for cfg in "CPU_AND_NE CPU_AND_GPU ne_gpu" "CPU_AND_NE CPU_AND_NE ne_ne" "CPU_AND_GPU CPU_AND_GPU gpu_gpu" "ALL ALL all_all" "CPU_ONLY CPU_ONLY cpu_cpu"; do
  a=(${=cfg}); .venv/bin/python -I scripts/coreml_eval.py models/embeddinggemma-2-coreml models/compiled ../.. $a[1] $a[2] results/coreml_$a[3].json
done
.venv/bin/python -I scripts/summarize.py results/coreml_*.json

# 3) Swift（FluidUse をパス依存で取り込む）
mkdir -p models/swift-dir && cd models/swift-dir
for f in embeddings.bf16 position_embeddings.f16 tokenizer.json config.json; do ln -sf ../embeddinggemma-2-coreml/$f $f; done
ln -sfn ../compiled/EmbeddingGemma2Text.mlmodelc . && ln -sfn ../compiled/EmbeddingGemma2Vision.mlmodelc . && cd ../..
(cd swift/FluidBench && swift build -c release)      # 初回は依存込みで約 11 分
B=swift/FluidBench/.build/release
$B/eg2-bench models/swift-dir ../runtime/data/embed_text_ids.json CPU_AND_NE results/swift_text_CPU_AND_NE.json
$B/eg2-image models/swift-dir ../runtime/data/embed_reference.json ../../poc/fixtures/screens CPU_AND_NE CPU_AND_NE results/swift_image_ne_ne_bicubic.json bicubic 280
.venv/bin/python -I scripts/score_swift.py ../.. results/swift_text_CPU_AND_NE.json results/swift_image_ne_ne_bicubic.json data/st_inputs.npz
# 予算: 最後の引数を 140 / 70 に。縮小方式の比較: bicubic を cg に

# 4) AX の読み取り確認（アクセシビリティ権限が必要）
$B/ax-probe
```

結果ファイル: `spikes/fluid/results/`（`coreml_*.json` = Python、`swift_text_*.json` / `swift_image_*.json` = Swift、`*.score.json` = Swift の採点、`*.log` に `/usr/bin/time -l` の最大 RSS・peak memory footprint）。

## 6. 未検証事項

- **AX の読み取り**: `ax-probe` の実行プロセスにアクセシビリティ権限が無く（`AXIsProcessTrusted() = false`）、前面ウインドウのタイトル・`AXDocument`・選択テキスト・AX ツリーの走査は**権限が必要で未検証**。確認できたのは前面アプリ名 / バンドル ID（権限不要）と FluidUse の `candidates()`（15 アプリ）だけ。`AXManualAccessibility` による VS Code（Electron）の AX ツリー取得とその副作用も未検証
- FluidUse のフォーム自動入力・各種判断モデル・デモ（CCCapture / CCMCP と無関係なため対象外）
- テキストが本当に ANE で実行されているか（op 配置）の確認。README の主張（100%）と、ANE 指定時に速く安定した計測結果からの推定にとどまる
- ANE コンパイルのキャッシュが消える条件（OS 更新・アプリ更新・署名の違い）。今回分かったのは「同じ中身でも別名のバイナリなら再コンパイルされる」まで
- 512 トークンを超える入力の扱い（切り詰めの影響）。評価データは最長 86 トークン
- 音声塔（`EmbeddingGemma2Audio`）。PRD は STT に WhisperKit を使うので計測しなかった
- 画像の予算 70 / 140 の品質。画面 14 枚の小標本でしか見ていない
- 実際のスクショ（ScreenCaptureKit、Display P3 など色空間付き、Retina 解像度）での一致。評価用 PNG は色プロファイル無しの 1440×900
- 画像前処理の Accelerate 化後の速度、`pack_256` を使った一括索引の品質（今回は速度のみ。1 件あたり 3.3ms）
- d1-3B（MLX、GPU）・WhisperKit と同時常駐させたときのメモリと遅延
- GPU 計測の揺れの原因（共有 GPU の負荷と見ているが切り分けていない）
- Python 経路の 2 回目以降のロード時間が 16.7 秒と 37.7 秒で大きく違う理由
