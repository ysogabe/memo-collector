# EmbeddingGemma 2 runtime comparison (#8)

2026-10-14、Apple M3 / 24 GiB、macOS 27.0.1。採用判断は [ADR-0003](../../docs/adr/0003-embedding-runtime.md)、数値は [results.json](results.json)。合成 48 文書 / 176 query、画像 4 枚 / 融合 4 件を各 3 回。画像は既存 `poc/fixtures/screens` の合成 fixture。ユーザー DB は開かない。

## 固定した条件と差

| | memo-collector | DigUp に最小パッチを加えた比較用コード |
|---|---|---|
| repository/revision | FluidInference/embeddinggemma-2-coreml / 3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4 | ggml-org/embeddinggemma-2-GGUF / bfcd298762cc34d0357ece5ebdd31791a3a374d8 |
| weight representation | fp16 Core ML、token table bf16 | Q8_0 GGUF text + mmproj |
| code | 実際の CoreMLEmbedder | ARahim3/DigUp f9b8106 + 本ディレクトリの patch |
| runtime | Core ML CPU+GPU / CPU+ANE を別計測 | llama.cpp b11461 / 4d756bc72bf00a4aacf410ae15a2d315f3db400d + 上流 no-logits patch / Metal |
| prompt/tokenization | `task: search result \| query:` / `title: … \| text:` | 同じ prompt。短い text 224 件の token ID は **224/224 一致** |
| pooling/vector | attention mask mean → 768d → MRL truncate / L2 | llama mean → 768d / L2 → 品質評価時 256d truncate / L2 |
| sequence cap | text/fused 512 tokens | full 2048 / text-only 512。今回の短文は cap に達しない |
| image budget | 280 tokens、interleaved text+image | 280 tokens、mtmd text+image（融合は比較用に追加） |
| image pixels | CoreGraphics sRGB + Swift bicubic | stb_image + Pillow 型 RGB bicubic |

同じモデル系列だが、元重みの byte-level 一致は未証明で精度表現も異なる。**純粋な同一重みランタイム比較ではない**。画像サイズは同じ 1008×624、resize 後 RGB hash は **0/4 一致**。画像/融合は同じ元画像による別経路の評価であり、同じ tensor を入れた性能測定ではない。4 件の短い融合のみ確認し、音声・長文の融合は対象外。

## 再現

Core ML モデルを既存 `cc-models prepare embedding` で用意する。GGUF は以下の固定 revision から取得し、`run.sh` が SHA256 を検証する。重み・生のベクトル・ログは Git に保存しない。

```sh
hf download ggml-org/embeddinggemma-2-GGUF \
  embeddinggemma-2-Q8_0.gguf mmproj-embeddinggemma-2-Q8_0.gguf \
  --revision bfcd298762cc34d0357ece5ebdd31791a3a374d8 --local-dir /tmp/cc-gguf
CC_MODELS_DIR=/path/to/models DIGUP_MODELS=/tmp/cc-gguf \
  CC_RUNTIME_RESULTS=/tmp/cc-runtime-results spikes/llama/run.sh
```

Swift、Xcode、git、Python 3、CMake（上流は未インストールなら uv を使う）を要する。専用 temporary clone の `codex/runtime-benchmark` でのみ DigUp に変更する。第三者コードの MIT 表示は `LICENSE-DigUp.txt`。hardwareは実行ホストから収集する。今回の対象はM3 24GiB。M4 32GBはユーザー指定により対象外で、前提条件にしない。

`run.sh` は推論を並列化しない。両 Swift ハーネスは Debug、llama C/C++ は上流 Release。Core ML は XCTest にリンクされ、native は小さな standalone executable。baseline footprint/RSS と unload 後も記録し、ハーネス由来の差を残す。Release アプリの性能を直接保証しない。

## 数値の読み方

- load は **新プロセス、既存 OS/model compile cache** の prepare + warmup。Core ML の完全な初回 ANE コンパイル、OS cache 消去、初回ダウンロードは測っていない。
- P50/P95 は各入力の 2〜3 回目。画像・融合は各 8 観測で尾部の推定は弱い。
- native batch は query 176 件の sequence packing（最大 16 sequence）。Core ML batch は現在の public scalar API の 176 回逐次呼び出しで、pack_256 の新実装を作っていない。
- peak RSS / physical footprint はプロセス全体。Core ML XCTest の起動時 RSS を含む。モデルだけの常駐量ではない。CPU seconds は `getrusage`、GPU/ANE の時間を含まない。
- 品質は全 runtime の **text-only 文書**を 256d で同じ holdout 正例 80 query に対して再順位付け。Recall@3 / MRR(depth30) / nDCG@3、同じ archived filter。回答なし query は vector top-k のため常に非空。#7 と同じ合成 v2 data だが、実画像を追加した検索品質の評価ではない。
- 当初のDebug測定では電力は未測定だった。main統合後にM3で管理者認証を経てpowermetricsを採取し、両SwiftのRelease比較を追加した。[追加結果とscope](../../docs/research/post-merge-runtime-validation.md)、[Release集計](results-release.json)、[SoC電力集計](../power/results-runtime-release.json)。ANE利用率はOSが提供しないため未提供と記録する。

未測定項目を 0 と解釈しない。長文/実画像や実hotkeyでの影響はruntime切替の具体化時に確認する。Release・電力の追加結果だけで入力経路や重みの互換性を保証しない。

## M3 の結果（2026-10-14）

| 構成 | cacheあり新process load ms | query P50 / P95 ms | image P50 ms | peak physical MB | peak RSS MB | 176 query batch ms |
|---|---:|---:|---:|---:|---:|---:|
| Core ML GPU full | 13,553 | 18.64 / 21.00 | 1,763 | 683 | 2,378 | 2,948（逐次） |
| Core ML ANE full | 12,868 | 7.33 / 8.54 | 1,818 | 313 | 382 | 1,329（逐次） |
| llama Metal full | 1,263 | 11.70 / 18.69 | 2,572 | 891 | 1,129 | 551（packing） |
| Core ML GPU text-only | 14,261 | 17.96 / 27.14 | — | 390 | 2,093 | 2,962（逐次） |
| llama Metal text-only | 444 | 12.19 / 25.36 | — | 221 | 522 | 1,780（packing） |

query-only と full では native の context/cap 設定が異なるため packing の値も違う。Core ML の巨大な peak RSS は XCTest 起動中の値も含み、温間常駐量の比較では physical footprint と before/unload を併読する。native query-only は before 約3 MB → peak221 MB、Core ML GPU text-only は before 約153 MB → peak390 MB。差分だけなら約218 / 237 MB であり、221 / 390 をそのままモデル量の削減と主張しない。
