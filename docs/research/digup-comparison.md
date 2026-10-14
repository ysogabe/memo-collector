# DigUp 実装調査と memo-collector の差分

調査日: 2026-10-14（JST）。関連: [Issue #6](https://github.com/ysogabe/memo-collector/issues/6)。

## 対象と検証範囲

- DigUp: [`f9b8106ffb8308b4f48b76149d270f7c2e6b4918`](https://github.com/ARahim3/DigUp/tree/f9b8106ffb8308b4f48b76149d270f7c2e6b4918)。公開ソースを一時ディレクトリに clone して追跡。
- memo-collector: [`32b1bdef2190e310f39f73136043acaa8ab0054c`](https://github.com/ysogabe/memo-collector/tree/32b1bdef2190e310f39f73136043acaa8ab0054c)。以下の memo 側パスはこの commit のもの。
- 静的なコード調査、既存計測資料の照合、Python SQLite の tokenizer 実験を実施。DigUp のモデル取得・ビルド・推論ベンチ・電力計測は未実施。コードコメント内の計測値は上流報告であり、今回の実測とは区別する。
- 採否案は [ADR-0001](../adr/0001-digup-search-adoption.md)、具体的な作業は [実装計画](../plans/digup-search-evolution.md)。アプリ・DB の実装は変更しない。

## 結論

参考にする価値が高いのは、キーワード検索と意味検索を独立に動かす構成、検索根拠の表現、ベクトル互換性の回帰検査、必要な処理だけを分離するヘルパーである。現行 Core ML 経路を維持し、日本語の評価基盤を先に作り、隔離した PoC で比較する。

DigUp を「日本語 FTS + RRF + XPC の実装例」と扱うのは正確でない。FTS は Porter + unicode61、融合は z-score と語の一致率による加点、プロセス分離は `Process` と標準入出力である。既存ファイルを再取得できる DigUp の破壊的な索引リセットも、本リポジトリの #9 の要件に合わない。

## コード参照

外部参照は commit を固定する。表中の D/M 番号で比較の根拠を追える。

| ID | DigUp の一次ソース | 確認点 |
|---|---|---|
| D1 | [ModelFiles.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/ModelFiles.swift), [LlamaModels.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/LlamaRuntime/LlamaModels.swift) | GGUF、revision、sha256、モデル探索 |
| D2 | [LlamaEmbedder.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/LlamaRuntime/LlamaEmbedder.swift), [ImageSizing.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/LlamaRuntime/ImageSizing.swift), [Model.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Model.swift) | 推論、pooling、前処理、プロンプト |
| D3 | [build-llama.sh](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/scripts/build-llama.sh), [llama.cpp-no-logits.patch](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/scripts/llama.cpp-no-logits.patch) | llama.cpp 固定 commit、パッチ、Metal ビルド |
| D4 | [IndexStore.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/IndexStore.swift), [Database.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Database.swift), [Indexer.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Indexer.swift) | DB、FTS、更新・削除、fingerprint |
| D5 | [Searcher.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Searcher.swift), [SearchText.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/SearchText.swift), [Vectors.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Vectors.swift) | 検索、融合、正規化、行列の解放 |
| D6 | [Worker.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpKit/Worker.swift), [WorkerService.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/digup/WorkerService.swift), [IndexService.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/digup/IndexService.swift) | JSON lines、索引ヘルパー、再開 |
| D7 | [Engine.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpApp/Engine.swift), [Watchdog.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/digup/Watchdog.swift), [ParentWatch.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/digup/ParentWatch.swift) | 再起動、idle、親プロセス終了 |
| D8 | [PowerPolicy.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpApp/PowerPolicy.swift), [IndexSchedule.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/DigUpApp/IndexSchedule.swift) | 電源・温度・時間帯の制御 |
| D9 | [main.swift の evaluate](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Sources/digup/main.swift#L470), [evals](https://github.com/ARahim3/DigUp/tree/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/evals), [ReferenceVectorTests.swift](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/Tests/LlamaRuntimeTests/ReferenceVectorTests.swift) | 評価形式、指標、数値互換性 |
| D10 | [LICENSE](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/LICENSE), [make-testbed.sh](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/scripts/make-testbed.sh), [sample_real.py](https://github.com/ARahim3/DigUp/blob/f9b8106ffb8308b4f48b76149d270f7c2e6b4918/scripts/testbed/sample_real.py) | ライセンス、生成データと個人ファイル採取 |

| ID | memo-collector の一次ソース（上記 commit） | 確認点 |
|---|---|---|
| M1 | `Packages/ContextCaptureKit/Sources/CCEmbedding/{CoreMLEmbedder,EmbeddingGemma2Towers,EmbeddingSupport,ImagePreprocessor,EmbeddingGemma2Tokenizer}.swift` | 推論・融合・256 次元・正規化 |
| M2 | `Packages/ContextCaptureKit/Sources/CCModels/EmbeddingModelPreparer.swift` | 固定モデル・ハッシュ・manifest |
| M3 | `Packages/ContextCaptureKit/Sources/CCStore/{StoreSchema,SQLiteRecordStore,EmbeddingCache}.swift` | Float32 BLOB・vDSP・更新トリガ |
| M4 | `app/ContextCapture/App/Live/{SearchIndex,SubstringSearchService,SwitchableEmbedder}.swift`, `Packages/ContextCaptureKit/Sources/CCCore/SearchIndexState.swift` | ready/rebuilding/degraded・フォールバック |
| M5 | `Packages/ContextCaptureKit/Sources/CCMCP/{MCPToolHandlers,WarmingQueryEmbedder}.swift`, `Sources/cc-mcp/CCMCPCommand.swift`（SwiftPM パッケージ内） | MCP の検索条件・ウォームアップ |
| M6 | `Packages/ContextCaptureKit/Sources/CCTriage/TriageQueue.swift`, `app/ContextCapture/App/Live/AppCoordinator.swift` | 保存順序・再開・再試行・競合 |
| M7 | `Packages/ContextCaptureKit/Sources/CCGuard/VisionSecretScanner.swift`, `Sources/CCCore/ContextRecord.swift`（SwiftPM パッケージ内） | OCR は保持しない、画像ガード |
| M8 | `poc/scripts/exp04_embedding.py`, `Packages/ContextCaptureKit/Tests/CCEmbeddingTests/{EmbeddingModelIntegrationTests,EmbeddingTestSupport}.swift`, `Tests/CCStoreTests/SearchBenchmarkTests.swift`（SwiftPM パッケージ内） | 現行評価の定義と制約 |

## 実装比較

| 観点 | DigUp | memo-collector | 計画への影響 |
|---|---|---|---|
| データ単位 | 既存ファイル + ページ・時間・コード位置など複数 segment [D4] | ContextRecord 1 件に注釈・画像・URL・意図。1 レコード 1 ベクトル [M3, M7] | 結果のキーは ContextRecord ID を維持。全 Mac のクローラは導入しない |
| モデル | `google/embeddinggemma-2` の `ggml-org/embeddinggemma-2-GGUF`、revision `bfcd298762cc34d0357ece5ebdd31791a3a374d8`、text/mmproj とも Q8_0 [D1] | 同じ base model 名の `FluidInference/embeddinggemma-2-coreml`、revision `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4` [M1, M2] | 変換版・精度が異なる。元重みの一致まで確認して比較する |
| 出力・格納 | mean pooling（`LLAMA_POOLING_TYPE_MEAN`）→ L2。768 次元、DB/検索行列は Float16、演算は Float32 [D2, D5] | Core ML の `embedding` 出力 768 → L2 → 先頭 256 を切り出し再正規化。DB/行列 Float32 [M1, M3] | 次元・格納精度を揃える実験と製品構成比較を分ける |
| 推論 | llama.cpp Metal、`n_gpu_layers = 999`、mtmd の画像・音声 encoder も GPU [D2, D3] | アプリは Core ML CPU/ANE。cc-mcp は初回特殊化を避け CPU/GPU、テキスト塔だけ [M1, M5] | #8 は ANE vs llama だけでなく cc-mcp の現行 GPU 経路も測る |
| 入力 | query/document の task prefix、llama vocab tokenizer。text-only 最大 512、full 最大 2048 token。画像は bicubic、予算 70/140/280/560/1120。音声は最長 30 秒 [D2] | 同じ query/document prefix、独自 tokenizer、最大 512 token。画像予算 70/140/280、bicubic。音声モデルは取得しない [M1, M2] | 長文や token budget を揃え、実入力トークン列を比較 |
| 画像と文字 | 別々の segment ベクトル。スクショ OCR は FTS 用、OCR ベクトルは作らない [D4 `migrateScreenshotText`, `Indexer.images`] | 注釈 + タイトル + 画像の interleaved 融合。URL/app は現行部分一致の対象だが、`runIndex` の埋め込み入力には直接足さない [M1, M6] | DigUp の公開 Embedder API に融合入力はない。#8 の融合比較には実験用アダプタが必要 |
| ベクトル検索 | 全件の行列内積、file ごとの best segment。モダリティごとの平均と共通標準偏差で z-score 化 [D5] | 全件の行列内積、上位 k。更新 version トリガによる一貫したキャッシュ [M3] | 両者とも ANN ではない。現規模で別のベクトル DB を導入する根拠はない |
| キーワード | FTS5、`porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'`。name/body、BM25、OR、語の coverage、NFKC など [D4, D5] | FTS なし。注釈/タイトル/URL/app の部分一致、AND、最大 5000 件。アプリと MCP で正規化・順位・状態条件が違う [M4, M5] | 日本語分割・短語・識別子を別に検証し、共通検索境界を作る |
| 融合・ゼロ件 | z ≥ 2 または coverage ≥ 0.5 を候補化。`meaningWeight * max(z,0) + wordsWeight * coverage^1.5 + kindHint`。識別子では語を重くする [D5] | ready 時はベクトル単独。degraded では失敗 ID を除外し部分一致を補う。意味スコアの棄却閾値はない [M4] | RRF は比較候補。DigUp 式も実験候補とし、少件数・類似記録・無関係 query を測る |
| 索引状態 | schema v5、meta の vector_source/fingerprint、pending/done/partial/skipped/failed。モデル変更で resetAll [D4] | schema v1、indexSignature = model revision/dimension/image tokens、外部 JSON 状態、failed_ids [M1, M3, M4] | #9 は既存機能の強化。DB 内の世代、入力 hash、原子的切替が不足 |
| 更新・削除 | ファイル変更で古い segment/FTS を削除し再 queue。rename は name/path を更新。segment は FK cascade、FTS は明示削除 [D4] | embedding は UPSERT、レコード削除で FK cascade、変更検知 version も更新 [M3] | FTS を足す場合は insert/update/delete と同じトランザクションで同期 |
| プロセス | 索引・抽出は CLI helper、query encoder は別 worker。`Process`、JSON lines、WAL、3 本の専用 queue [D6, D7] | STT・guard・intent・embedding はアプリ内、cc-mcp は独立プロセス [M5, M6] | XPC は DigUp の採用例ではない。現行と Process/XPC を段階比較 |
| 解放と復旧 | close/プロセス終了、idle で encoder と mmap 行列を解放。watchdog は footprint 4〜8GB/1ファイル15分、exit 75 と記録で次回スキップ、10分内の再起動は3回まで。親終了も監視 [D5–D7] | 直列 TriageQueue、重複統合、ステップ独立失敗、resumePending、d1 は10分 idle解放、キャプチャ中は次ステップを止める [M6] | worker のタイムアウト・上限付き復旧を参考にする。#10 の成立条件は自分のキャプチャ負荷で測る |
| 低電力 | Low Power Mode、thermal serious/critical、設定によるバッテリー制限は backfill を止める。少量の新着は優先。通知主体、時間帯制御も別実装 [D8, D6] | キャプチャ優先の pause/resume はある。電源・温度による backfill 制御はない [M6] | 過去分の再索引だけを遅延する policy が候補 |

Core ML 変換の fp16 重み・bf16 token table・mean pooling は、revision ファイルが `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4` の取得済みモデルの README/config と既存の [Fluid 調査](fluid-inference.md) に記述されている。今回 Swift の `embedding` 出力・L2・切り出し・入力 mask は確認したが、モデルグラフ内の pooling 演算と両変換の元重み SHA の一致は再検証していない。#8 の準備で確定する。DigUp の D1 コメントは元モデル revision を `914f7f8` と記すが、コメントだけで同一重みと断定しない。

## 日本語 tokenizer の小実験

Python `sqlite3`（SQLite **3.53.3**）、インメモリ DB で確認。アプリの GRDB/SQLite そのものの動作確認ではない。

| 保存文字列 | クエリ | DigUp と同じ tokenizer の MATCH | trigram の MATCH |
|---|---|---|---|
| 日本語検索の実装方針 | 日本語検索 | 0 件 | 1 件 |
| 日本語検索の実装方針 | 検索 | 0 件 | 0 件 |
| CoreML の API を調べる | API | 1 件 | 1 件 |
| ANE | ANE | 1 件 | 1 件 |
| https://github.com/ysogabe/memo-collector/issues/6 | #6 | 1 件 | 0 件 |
| 同上 | issues/6 | 1 件 | 1 件 |

`#6` の unicode61 一致は記号を含む厳密一致の証拠ではない。query の `#` が tokenizer で落ちた結果であり、DigUp の `Searcher.terms` では単独の `6` は2文字未満で捨てられる。実製品の query 処理まで含めた #7 が必要。

[SQLite の公式仕様](https://www.sqlite.org/fts5.html#the_trigram_tokenizer)でも trigram MATCH は3 Unicode文字未満を拾えない。trigram を選ぶ場合も短語検索、Issue 番号・URL・API 名の構造化照合を用意する。BM25 の値は小さい方が良いことにも注意する。

再現コード（モデルやユーザーデータを使わない）:

```python
import sqlite3
print(sqlite3.sqlite_version)
db = sqlite3.connect(':memory:')
rows = [(1, '日本語検索の実装方針'), (2, 'CoreML の API を調べる'),
        (3, 'https://github.com/ysogabe/memo-collector/issues/6'), (4, 'ANE')]
for name, tokenizer in [('digup', "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"),
                         ('trigram', 'trigram')]:
    db.execute(f'CREATE VIRTUAL TABLE {name} USING fts5(body, tokenize="{tokenizer}")')
    db.executemany(f'INSERT INTO {name}(rowid,body) VALUES (?,?)', rows)
    for query in ['日本語検索', '検索', 'API', 'ANE', '#6', 'issues/6']:
        pattern = '"' + query.replace('"', '""') + '"'
        ids = list(db.execute(f'SELECT rowid FROM {name} WHERE {name} MATCH ?', (pattern,)))
        print(name, query, ids)
```

## 評価データ・指標・再現性

D9 の JSON は `base`, `queries[{q, expect:[相対パス@位置範囲], tag?, kind?}]`。複数正解は「どれか一つの正解への最初の順位」として集計する。`evaluate` の **R@1/5/10 は HitRate@k** であり、正解集合全体を分母にする Recall@k ではない。MRR も取得深さ `-n` の外側は0となる。nDCG、ゼロ件正解の専用指標、品質回帰を落とす CI gate はこの経路にはない。

commit 固定 JSON の件数は synthetic **37**、code **41**、multilingual **48**。multilingual はベンガル語・アラビア語と英語の往復で、日本語検索の評価にはならない。いずれにも `expect: []` はない。

再現の構成は `scripts/build-llama.sh` 等で native runtime を用意 → 合成 fixture を生成 → `digup index` → `digup eval evals/<file>.json -n 10`。詳細オプションは同 commit の `digup --help`。`worker/pyproject.toml` と `digup_worker.py` は Python MLX の参照経路で、製品版 llama.cpp 経路と区別する。

`make-testbed.sh` の冒頭は **自分の実ファイルを sample_real.py で採取する**。今回実行していない。#11 では独自の匿名・合成 ContextRecord を作り、個人ファイル採取を再現手順へ含めない。画像・音声・サンプル素材ごとの出典と利用条件を記録する。DigUp 本体の MIT（D10）と、モデル/同梱第三者のライセンスは別に確認する。

現行 M8 の `recallMRR` / `recall_mrr` は `|top-k ∩ relevant| / min(k, |relevant|)`。通常の Recall（分母は `|relevant|`）とも DigUp の HitRate とも違う。旧 PoC の **0.933** はこの定義と旧 dataset に紐付けて保存し、新セットの合格値に転用しない。既存評価には日本語の合成画面/注釈と参照ベクトルがあり、数値検証は再利用できる。1万件の Store ベンチは乱数ベクトルによる速度検証であり、検索品質の証拠ではない。

## memo 側で先に解消する差分

1. **原子的な索引世代がない**: ベクトルはレコードごとに上書きし、互換性と完了状態は DB 外の JSON で持つ。再構築中はアプリも MCP も部分一致へ落とし、degraded はアプリだけ成功分を使う。途中の再開は全件やり直し。旧索引を保持した原子的切替・ロールバックはない。JSON 書き込み失敗もログだけで、DB と状態ファイルは一つのトランザクションにならない [M3, M4]。
2. **編集との競合**: `runIndex` は最新注釈/タイトルを読み直した後、別トランザクションで `setEmbedding`。間の編集で古いベクトルが入りうる。既存 [#5](https://github.com/ysogabe/memo-collector/issues/5) の対象と統合し、入力 hash に対する条件付き保存にする [M6]。
3. **復旧が「結果の欠如」依存**: queue はメモリ内、起動時に guard/triage/embedding の有無から再生成する。編集後の再処理要求を失った場合、旧 embedding が存在すると起動時に未完了と判別できない [M6]。永続 job と input version を #9/#10 の共通契約にする。
4. **OCR の検索元がない**: VisionSecretScanner は秘密の bbox/kind だけを残し、OCR 本文を保存しない。検索用 OCR 索引を追加するならマスク画像か検出範囲を除いた文字列を使い、MCP の excerpt に元画像の秘密が出ない契約が先に必要 [M7]。
5. **UI と MCP の検索差**: アプリは score 順の部分一致、MCP はページ走査の新しい順。MCP は archived を除外する。Inbox の scope は上位30件を取ってから絞るため、候補段階の条件も共通化する [M4, M5, `app/ContextCapture/UI/InboxViewModel.swift`]。
6. **保存前 STT**: AppCoordinator は STT → 添付保存 → Record insert → 非同期 triage。STT が通常失敗したときは音声付き記録を残すが、STT 完了前のクラッシュには永続記録がない。#10 の「先に保存」は guard/intent/index の既存順序と、STT 前の durable capture を分ける。後者は noSpeech を保存しない現仕様にも関わる [M6]。

## 採否案

| 設計 | 判断 | 条件・理由 |
|---|---|---|
| 独立した keyword/semantic 経路、根拠付き結果、互換性の固定入力テスト | 設計として採用 | #11/#7/#9 で現在の ID・guard・MCP 契約に合わせる |
| DigUp の Porter/unicode61 を日本語検索へ直接移植 | 不採用 | 日本語中間部分・短い番号を扱う要件に不足 |
| RRF と DigUp 型 z/coverage 加点 | 比較対象として保留 | 日本語・少件数・ゼロ件・類似記録の holdout で採否を決める |
| Core ML → llama.cpp の製品置換 | 保留 | #8。融合入力、重み、精度、ANE 初回ロード、MCP GPU、競合時 STT を比較 |
| Process helper / XPC、idle 解放、電源による backfill 遅延 | 保留 | #10。既存 pause/resume を維持して実測。IPC timeout と上限付き復旧を追加する |
| DigUp の resetAll、file/segment schema、全ファイル crawler | 不採用 | #9 の旧索引保持と ContextRecord 中心の製品境界に合わない |
| mmap/Float16 行列へ変更、ANN 導入 | 現時点では保留 | 現行256d Float32 は1万件で約10MB。品質/サイズ/実負荷の根拠が出てから |

採用時の注意: DigUp の `EmbeddingWorker.readReply()` は標準出力の `availableData` を同期的に待ち、要求ごとの timeout は実装されていない。query encoder の停止や応答しない worker を想定した堅牢性を、そのまま引き継げるとは判断しない [D6]。

## 未検証事項

- DigUp 製品版の推論時間・footprint・電力、こちらの融合に合わせた llama.cpp 経路。
- 両変換の元重み revision/ハッシュ、Core ML グラフ内 pooling、トークナイザと縮小画素の同条件比較。
- 実際の Swift/GRDB での trigram availability、短語経路の品質/遅延/索引サイズ。
- 日本語 holdout、障害注入、検索用 OCR を保存する場合のガード動作。

Issue #6 の PR 提出・レビュー・完了扱いは別の手順。本調査文書の作成だけでは Issue を閉じない。
