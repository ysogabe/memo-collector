# DigUp 調査後の検索・索引・推論の実装計画

作成: 2026-10-14。基準 commit: memo-collector `32b1bdef2190e310f39f73136043acaa8ab0054c`。

根拠は [DigUp 比較調査](../research/digup-comparison.md)、方針は [ADR-0001（提案）](../adr/0001-digup-search-adoption.md)。本文は開始時の実装計画で、候補APIを含む。現在の実施状況と確定した保存契約は末尾の成果物・各ADRを参照する。

## 推奨順序

**#6 → #11 の最小評価基盤 → #7 の隔離 PoC** を先に進める。#9 の保存契約設計はこの間に行い、製品の索引を切り替える前に実装する。#8 は同じ評価基盤を使う独立ベンチ、#10 は基準計測と永続 job を先に進め、ヘルパーの採否を最後に判断する。#11 の CI は後続の成果に合わせて拡張する。

| 段階 | Issue | 成果物/PR 単位 | 終了条件 |
|---|---|---|---|
| A | #6 | 比較調査 + ADR + 本計画 | commit 固定の根拠と未検証事項をレビュー。文書 PR の提出で #6 の完了条件へ進む |
| B | #11 前半 | 合成 corpus・golden query・評価 runner・現行 baseline | ID と正解が固定され、複数正解/ゼロ件と指標の計算を検証できる |
| C | #7 | 日本語 keyword と fusion の隔離 PoC | 同一データの比較表、失敗例、採否。製品への導入は別 Issue/PR を提案 |
| D | #9（設計は B/C と並行可能） | 条件付き embedding 保存 → 世代 schema/移行 → shadow rebuild/切替 | 実 DB の非破壊移行と障害注入が通る。#5 の重複項目も整理 |
| E | #8 | native llama の比較 adapter と測定手順/結果 | モデル・重み・精度・入力差を明示した品質/速度/電力比較。置換の ADR 更新 |
| F | #10 | 基準計測/永続 job → 最小 helper PoC → 採否 ADR | M1 保存速度を悪化させず、落ちた後も要求を回復できる |
| G | #11 後半 | 品質回帰 CI + 実モデル/性能の専用手順 | baseline 差分と劣化閾値を固定し、モデル未準備を合格と取り違えない |

## B: #11 の最小評価基盤

候補配置: `evals/search/{records,queries,manifest}.json`、`scripts/eval-search.*`、評価 runner（SwiftPM の実行 target か Python scorer + Swift 検索 adapter）。現行 Swift 実装を baseline として実際に呼び、Python で似せた検索を baseline と呼ばない。

- 合成・匿名 ContextRecord と画像を使用し、各素材の出典/利用条件、生成 seed、入力 hash、corpus version を manifest に記録。既存 `poc/fixtures` は由来を確認して再利用する。
- query は `id`, `text`, `relevant[{record_id, grade}]`, `tags`, `filters`, `split` を持つ。空の relevant を正解なしとして定義。最初は100〜200 query を目安とする提案で、件数自体は採用の証拠ではない。
- 言い換え、英日混在、2文字以下、URL/#6/#60/数値、API名/エラーコード、全半角、OCR/STT ノイズ、近い記録、archived/guard/intent 条件、無関係 query を含める。dev/holdout は同じ元記録やその複製を跨がせず分ける。
- ID で重複除去した順位を評価。Recall@k = `|top-k ∩ relevant| / |relevant|`、HitRate@k = `1[交差あり]`、MRR は先頭正解順位の逆数（取得深さも明記）、nDCG@k は grade と gain の定義を固定。R@1/3/10、HitRate、MRR、nDCG、タグ別結果を出す。
- 正解なし query は Recall/MRR の平均から分け、空結果率と誤ヒット率を出す。旧 PoC の分母 `min(k, |relevant|)` の値は legacy metric 名と dataset ID 付きで別保存する。
- レポートへ query ごとの順位・検索根拠、model/pipeline version、OS/hardware/runtime、cold/warm、索引時間/容量、全検索時間と各内訳を残す。品質に使った同じ corpus と、1k/10k の容量/速度用 corpus は識別する。
- モデル不要の CI は固定ベクトル/順位 fixture で scorer、融合、filter、更新整合性を確認。実モデルの品質は固定モデルを備えた macOS 実行で再生成する。キャッシュベクトルだけの CI は embedding runtime の回帰を保証しない。

現行の `EmbeddingModelIntegrationTests` は数値互換性を再利用し、`SearchBenchmarkTests` は速度検証を再利用する。現状 `.github` の CI はないため、#11 後半で workflow と専用実行の構成を新設する。意図分類の criteria/threshold/coverage は #2 のままにする。

## C: #7 の日本語ハイブリッド検索 PoC

PoC は `spikes/search/` と一時 DB で行い、通常のデータルートや索引状態を書き換えない。#9 の未完成を理由に PoC を止める必要はない。

1. **現行入力を固定**: 実製品の embedding は注釈/タイトル/画像。旧 PoC のメタデータを足した text と区別する。UI と MCP の現在の正規化、AND、順位、5000件走査上限、filter を baseline variant として記録する。
2. **keyword 比較**: 同じ annotation/title/url/app の field から、現行部分一致、unicode61 対照、trigram + 短語経路、必要なら日本語分割を比較。GRDB が使う SQLite version/FTS5/trigram を実際に probe する。
3. **厳密照合**: URL 全体/host/path、`owner/repo#number`、API 名、エラーコードを専用 field/token で照合。`#6` が `#60`、API 名が別語の途中に偶然一致する例を負例にする。短語は範囲を絞った照合を比較し、全件走査の遅延も測る。日本語正規化で濁点を落とす案は自動採用しない。
4. **独立 retrieval**: query と同じ filter を keyword/semantic の候補取得に適用し、各上位候補を ID で集約。候補数（例:各50/100件）と空の query 処理を設定として記録。
5. **fusion 比較**: semantic 単独、keyword 単独、RRF（例 `sum(weight / (60 + rank))`）、必要なら DigUp 型 z/coverage を評価。RRF の60/weight/候補数は dev で決め holdout では固定。BM25 と cosine の生値をそのまま足さない。DigUp 型は1/10/100/1000件や類似記録を加えた corpus で分布依存を測る。
6. **根拠/API 案**: `SearchRequest{text, filters, limit}` と `RankedCaptureHit{recordID, rank, rankingScore, semanticScore?, keywordRank?, evidence[]}`、`SearchResponse{hits, mode, notice?, indexGeneration}` を候補にする。evidence は field、元文字列の範囲、必要な短い excerpt。意味のみの画像ヒットに文字一致の根拠を捏造しない。合成 score を cosine/確率として扱わない。
7. **ゼロ件と性能**: RRF は並び替えだけなので、正解なし query の棄却は別に設計/調整する。end-to-end P50/P95、query embedding/DB/fusion の内訳、cold/warm、サイズ、索引時間を測る。300ms debounce 等の UI 待ちと純粋な検索時間は分ける。

OCR は後半の別 variant。現行 scanner は本文を捨てるため、新たな検索用 OCR projection が要る。`pending/needs_review` では OCR excerpt を MCP に出さず、masked ではマスク画像から生成する等の契約を確定する。まず OCR 未保存でも動く評価を進める。

本実装を提案するときの変更点:

- `CCCore` に共通 request/hit/evidence、`CCStore` に keyword projection と query、必要に応じ `CCSearch` target に normalization/retrieval/fusion を配置。
- `StoreSchema.swift` の FTS migration と `SQLiteRecordStore` の insert/update/delete を一つの transaction で同期。notes/URL/画像/guard の変更ごとに projection を更新するかを明示。
- `EmbeddingSearchService` と `MCPToolHandlers.searchCaptures` を共通検索境界へ接続。`InboxViewModel` が結果を後から絞る方式を候補前 filter へ変更する。
- 準備中・失敗時も keyword が独立に返る契約を維持し、MCP の `mode/fallback_reason` を互換的に拡張する。

採用基準の提案: holdout の識別子層で改善し、全体の Recall@3/MRR/nDCG が現行より2ポイントを超えて劣化しない、ゼロ件誤ヒット率を悪化させない、guard違反0。速度はベースライン取得後に上限を固定する。小セットの1件の重みと信頼区間も示す。これらは今回の測定結果や既承認の閾値ではない。

## D: #9 の索引世代と非破壊再構築

既存 `indexSignature`、manifest、version trigger、degraded/failed_ids を活かす。DigUp の `resetAll` を移植しない。最初の PR で [#5](https://github.com/ysogabe/memo-collector/issues/5) の check-then-act を解消する。

候補 schema:

- `index_generations(id, compatibility_key, model_manifest, pipeline_version, dimension, vector_encoding, state, created_at, ...)`
- `record_embeddings(record_id, generation_id, input_version, input_hash, vector, ...)`、主キー `(record_id,generation_id)`、record の FK cascade。
- `search_index_pointer(singleton, active_generation_id)`。DB 内で pointer/世代 state を同じ transaction で変更する。
- 検索入力の version/hash は annotation/title と画像 content/path、実際に索引へ入れる field、前処理 version を含む。notes/status 等、検索本文や候補条件だけに関わるものは更新責任を分ける。
- artifact 情報（重み revision/runtime build/quantization 等）と compatibility_key（pipeline とベクトル空間）を区別する。CPU/GPU/ANE を同じ互換群に入れるのは既存 parity 検証を継続する場合。別ランタイムは初期状態では別世代。

保存/切替手順:

1. 旧 schema の `embeddings` と `records` をそのまま保持し、新テーブルへコピーする。旧 JSON が ready で互換性を証明できる場合だけ legacy 世代を active とする。JSON 不在/矛盾時は推測せず keyword fallback + shadow rebuild。migration 前は書き込みを止めるか SQLite の backup API で整合した backup を作り、WAL 中の DB 単体コピーを手順にしない。
2. record 入力を変更する transaction で input_version を更新し job を残す。推論結果は `saveEmbeddingIfCurrent(recordID, generation, expectedInputVersion/hash, vector)` の一つの transaction で確認して保存する。削除済み/変化済みなら書かず、最新 job を残す。
3. 新世代を shadow に作成し、DB の進捗から再開。全 ID/JSON の全件デコードではなく ID/version をページで取得する。rebuild 中の新着・編集は active/target の job に反映し、削除は両世代へ cascade。
4. active 世代と対応する query encoder が利用可能なら旧索引で検索を続ける。旧 encoder を保持できない設定変更では、keyword へ落として理由を返す。両モデルの同時常駐を無条件に要求しない。
5. 書き込み transaction の切替点で最新 input_version の未完了/失敗がないことを検証し、新 pointer を commit。競合中の編集もこの transaction と直列化する。query と索引は一つの世代 snapshot を使い、途中の pointer 変更ではリトライまたは旧 snapshot を完了させる。
6. MCP も DB の pointer/compatibility を読む。`search-index.json` は移行期の互換用出力に限定し、JSON 出力失敗で DB の世代を誤認しない。古い reader が混在する期間の拒否/フォールバックも migration 契約にする。
7. 検証済みの旧世代を保持し、失敗時は pointer と encoder 対応を戻す。元記録を消さない。旧世代の期限/容量による cleanup は切替成功と reader の解放を確認して実行する。

テスト: v1→新schema、WAL/別プロセス cache invalidation、同次元で異なるモデル、編集の保存前/直後、画像変更、notes/URL変更、削除、再構築 kill/restart、部分失敗、disk-full/JSON書き込み失敗、設定再変更、切替中の検索、rollback。既存 `SearchIndexMaintainerTests` 等を拡張し、入力版不一致を本物の transaction で再現する。

## E: #8 の runtime ベンチ

候補配置: `spikes/llama/`。製品の `CCEmbedding` や active 索引の置換は行わない。

- DigUp 固定 source と同じ llama.cpp **b11461 / `4d756bc72bf00a4aacf410ae15a2d315f3db400d` + no-logits patch** を出発点として adapter を作る。モデルファイル revision/sha256、ビルド設定、patch hash を記録。
- Core ML/llama の元重み revision/hash、tokenization、mean pooling、L2、document/query prefix、画像サイズ/pixel値、token budget、最大長を確認。同じモデル名だけで同条件としない。
- 第1段階は text-only、次に画像のみ。両方を768次元で比較し、同じ先頭256への切り出し/再正規化でも品質を比較する。Q8_0 と fp16 の差が残る比較は「runtime+precision 構成比較」と記す。純粋な runtime 効果を分離できない場合はその制約を残す。
- 融合入力は DigUp の公開 API にないため、専用 spike で既存 interleaved 列を llama に通す。参照との token/pixel/vector parity が取れるまで、画像単独の値を融合性能として報告しない。音声は現行 embedding では非対象で別評価にする。
- cold を初回特殊化/同じバイナリの再起動に分け、warm、single/batch、idle-after-unload、STT/triageとの競合を測る。アプリ ANE、cc-mcp CPU/GPU、llama Metal を別行にする。
- query/document/image/fused ごとの P50/P95、load/compile、index時間、常駐/ピーク RSS **と phys_footprint**、GPU/ANE・MLXの値、電力を採れる範囲で記録。総プロセスの footprint と startup/IPC も含める。
- M3 24GBで再現可能な手順を用意する。M4 32GBは2026-10-14のユーザー指定により対象外とし、利用を前提にしない。回数を固定し、計測中の他負荷と cache 状態を記録する。

採用条件は #11 の品質を維持し、製品上の測定対象（初回利用・検索・STT競合・メモリ等）で改善があること。旧 Core ML の過去の「約5ms」「融合0.59〜0.94秒」や DigUp コメントの値との直接比較はしない。採用するなら #9 の新世代として索引し直す。

## F: #10 の永続 job と最小ヘルパー

現行 TriageQueue の直列処理、重複統合、手動意図を上書きしない契約、capture pause/resume、d1 idle 解放を維持して比較する。

1. 現行の保存・triage・query を測定し、モデルごとの load/unload と UI応答、総 footprint、STT breakdown を記録。
2. `processing_jobs(record_id, step, input_version, target_generation, state, attempts, next_attempt_at, lease, error_code)` 等の永続要求を #9 の入力版と接続。record 更新と job upsert は同一 transaction。pending→running→succeeded/retry_wait/failed/cancelled を定義し、重複要求をまとめ、期限切れ lease を回復する。
3. まず同一プロセスで永続 job を実装/検証し、落としても最新要求を再開できることを確認。ステップの結果は条件付き保存し、同じ job の再実行でも結果を重複させない。
4. guard/embedding など計測で効果が出そうな一つの境界だけ helper PoC にする。JSON lines の Process と XPC は別の候補。request ID、入力版、世代、shape/size上限、timeout/cancel、親終了、最大再起動回数と backoff を定義。helper が DB を直接更新するか親が結果を保存するかを固定し、二重 writer の責任を曖昧にしない。
5. 新着の処理と backfill を区別し、低電力/thermal/電源変化で backfill を遅延する。ユーザーの新規保存・検索や guard の外部公開判断を backfill の待ちへ巻き込まない。
6. kill/hang/重複応答/部分失敗/設定変更/編集/削除/再起動で測定。M1 の押下→録音開始と解放→保存、復旧時間、索引の freshness を現行と同条件で比較して ADR を更新。

**STT 前の永続化は別の変更**: 現在は STT 後に Record を作る。「音声あり」を早期確定して録音/スクショを durable capture として保存し、STT完了後に annotation を埋める案は耐クラッシュ性を改善するが、noSpeech を保存しない仕様、再試行 UI、音声保持期間に関わる。まず STT後→triage前の永続 job を成立させ、必要なら暫定 capture 状態/回復手順を別 PR で設計する。

## 検証と Issue の責任範囲

- #6 は調査・ADR の文書 PR。#7/#8/#10 の PoC は製品採用と分ける。#9 は移行と実装、#11 は共通の検索品質基盤。
- #2 の意図分類評価は変更しない。#3 のモデル供給網検証はモデル manifest 側、#9 は検索空間の互換性と世代を扱う。#5 の embedding 競合/全件 decode は #9 に集約し、Issue 更新時に重複を明記する。
- docs の変更はリンク/パス/commitとdiffを確認。コード実装では関連 Swift tests、DB migration/障害注入を実施し、製品接続時に `scripts/check.sh` と実機 M1/MCP を確認する。
- runtime/品質の実モデルジョブは未準備を skip成功として扱わず、必要な fixture と model の欠如を失敗とする。機械依存の速度閾値は通常 CI と別に判定する。
- 進捗は各実装 PR と評価レポートで追跡する。本計画そのものを PoC や製品実装の完了証拠として扱わない。


## 実施状況（2026-10-14）

| 段階 | 成果物 / PR | 判断 |
|---|---|---|
| #6 | 調査 / ADR-0001 / [PR #12](https://github.com/ysogabe/memo-collector/pull/12) | 上流実装をcommit固定で分析 |
| #11 最小版 | 評価runner/合成baseline / [PR #13](https://github.com/ysogabe/memo-collector/pull/13) | #7 の前に指標を固定 |
| #7 | `spikes/search` / [PR #14](https://github.com/ysogabe/memo-collector/pull/14) | nDCGと負例の採用条件未達で融合は保留 |
| #9 | ADR-0002 / [PR #15](https://github.com/ysogabe/memo-collector/pull/15) | 製品へ非破壊migration/shadow世代/CASを実装。全QA成功 |
| #8 | `spikes/llama` / ADR-0003 / [PR #16](https://github.com/ysogabe/memo-collector/pull/16) | M3のRelease/SoC電力/GPU residencyを追加、Core ML維持。ANE利用率はOS未提供、M4は対象外 |
| #10 | `spikes/worker` / ADR-0004 / [PR #17](https://github.com/ysogabe/memo-collector/pull/17) | 実helper障害/永続jobとactual coordinatorの3モデルfixture E2Eを測定。製品導入は保留、実hotkey/UI/batteryは未測定 |
| #11 後半 | [回帰CI結果](../research/search-regression-ci.md) / `scripts/search-quality.sh` / `scripts/search-model-evaluation.sh` | 品質CI + 実モデル専用job、両コマンドをローカル実行 |

全PRはレビュー前で未merge。#9以外の製品方式変更は採用していない。旧vectorのprovenanceを推測してactive化せず、初回もshadow再構築する保存契約で確定した（ADR-0002）。開始時に想定したtable/API名との差は実コードを正とする。

追加測定: [main統合後のRelease/電力/actual coordinator結果](../research/post-merge-runtime-validation.md)。M1はmilestone 1でありCPU名ではない。
