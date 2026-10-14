# 日本語検索の固定評価セット

Refs #11 / #7。現在の `search-ja-v2` は新規に執筆した合成データ48件と176クエリ。#11前半の `search-ja-v1`（144クエリ）は先行PRの固定ベースラインとして保持する。個人のDB・音声・スクリーンショットやDigUpの評価素材は使わない。生成データは CC0-1.0。生成コードと評価コードはリポジトリの扱いに従う。

## 再現

Apple Silicon、macOS 15以上、Swift 6、プロジェクトのモデル準備が必要。初回のビルドではSwiftPMの依存を取得する。

```zsh
python3 evals/search/generate.py
swift test --package-path evals/search/Runner --disable-keychain
CC_SEARCH_EVAL_OUTPUT=/private/tmp/cc-search-evaluation scripts/eval-search.sh \
  --models /path/to/model-root --compute cpuAndGPU --live-queries
```

モデルルートの下に `embeddinggemma-2/` が必要。モデルを省略すると `CCPaths` の既定/`CC_MODELS_DIR` の場所を読む。評価ストアは常にUUID付きの一時フォルダに作成して終了時に削除し、`CC_DATA_DIR` のDBは開かない。fixtureとモデルを読み、指定の出力先にだけレポート/ベクトルcacheを書き込む。

Core MLの文書入力は製品の `runIndex` と同じ注釈＋ウインドウタイトル。画像のない最小セットで、`screen` があるfixtureだけ画像を融合する。URL/appを埋め込み本文へ足さない。

`--live-queries` は現行 `CoreMLEmbedder` のクエリ推論を検索時間に含める。省略時は同じモデルで生成した固定ベクトルから検索し、レポートは **retrieval only** と明記する。モデル未準備は失敗となり、フェイク推論やkeywordへの自動fallbackでvector測定を成功扱いしない。cacheはcorpus/queryのsha256とモデルシグネチャ・次元で検証し、不一致は失敗。再生成には別cache先か `--refresh` を使う。

## 現行の基準線

`baseline_mcp_vector` / `baseline_mcp_keyword` は実際の `MCPToolHandlers.call(search_captures)` と `SQLiteRecordStore` を呼ぶ。前者には準備済みのembedder、後者にはembedder無しを渡し、結果の `mode` を検証する。新しい検索を既存方式の基準線へ混ぜない。Inboxのscopeやアプリの部分一致のscore順はこの基準線には含めない。

既定で深さ30件、クエリごとに3回。1回目の分布と、2回目以降のwarm P50/P95を別集計する。モデルload/prepare、DBの索引時間は別項目。取り出し深さとMRRの打ち切りを記録する。全体/split/tagごとの指標と、各クエリの結果ID・score・測定時間をJSONに出す。速度値は環境依存で通常の品質CI閾値には使わない。

## 正解と指標

- topic単位でdev/holdoutに分割。関連する記録とその言い換えを同じsplitに保持。正解なしクエリも両splitで異なる文例。
- `relevant` はContextRecord IDとgrade（主要回答2、関連資料1）。複数正解対応。archivedの正解は `includeArchived` がtrueのクエリだけ。
- Recall@1/3/10の分母は正解ID集合の数。HitRateは正解が一件でも入る割合。旧PoCの分母 `min(k, relevant.count)` と別の指標。
- MRRは最初の正解までの逆順位。取得深さの外側は0。nDCGはgain `2^grade-1` と割引 `log2(rank+1)`。
- 正解なしはRecall/MRR/nDCGの平均から分け、空結果率/誤ヒット率を集計。重複IDは順位計算前に除く。

この最小セットではOCR/STTノイズを注釈の誤字として検証する。画像、Vision OCR、匿名化した実利用分布の検証は後続。合成セットの値だけで製品全体の品質を保証しない。

## 回帰評価の拡張

品質 CI と実モデル評価は以下のコマンドで実行する。固定ベクトルの CI は推論ランタイムの回帰を保証しない。モデル切替は別 cache/索引世代で評価する。Vision OCR、画像主体の品質と実利用分布は今回の text corpus の保証範囲外。

#7 の `search-ja-v2` は同じ合成48記録に、日本語の3文字以上の部分一致と全角識別子のクエリを追加し、ノイズ文例を明示的な誤字にした176クエリ。比較はすべてv2の同じquery hashで再実行する。`baseline-quality.json` は #11 前半のv1に固定された記録で、v2との数値差を検索アルゴリズムの差と見なさない。

## 品質回帰 CI と実モデル job (#11 後半)

```sh
scripts/search-quality.sh
CC_MODELS_DIR=/path/to/prepared/models scripts/search-model-evaluation.sh
```

通常の [search-quality.yml](../../.github/workflows/search-quality.yml) は固定 256d Core ML ベクトルを temporary の **実 SQLiteRecordStore** へ signed CAS で挿入し、世代をactivateして現在の vDSP 検索を実行する。native FTS5 / 短語・識別子fallback / RRF / gateも毎回実行する。保存済みランキング/集計を正解として再出力するだけの CI ではない。`CC_SEARCH_CONTRACT_ONLY=1` は Runner のモデル executable を除外し、MLX / Core ML / Metal を buildしない。Kit の pinned dependency manifestにはSwift6.4が必要なので、[GitHub公式のXcode27 preview runner](https://github.com/actions/runner-images/issues/14404)を使用する。

`frozen-vectors.json` は合成v2の48記録・176queryだけから生成したもの。元cacheのcorpus/query hash、モデルpipeline/key、次元、coverage、有限値、L2を検証する。manifestのSHA256とgeneratorの完全再現も確認。モデル重み、ユーザーDB、実音声/実スクリーンショットは含まない。検索 corpusとqueryの利用許諾はCC0。

`golden-quality.json` は同じ実検索から固定した **v2品質 baseline**。旧v1の `baseline-quality.json` と区別する。深さ30、RRF k60 / 候補50 / gate0.65（#7のdevで固定）を使用する。CIでは再調整しない。各modeのALL/dev/holdout/tagごとにRecall/HitRate/nDCG@1/3/10・MRRを比較し、低下 **2pp超** を失敗とする。正解なしの空結果率低下/誤ヒット率増加は許容しない。query/正例/負例の件数変化、欠損mode/cohort/metric、NaNも失敗。

閾値は #7 の提案を品質 gate の初期値としたもので、外部データで統計的有意性を検証した値ではない。小さなtagでは1件の変化でも大きな差になり、原因をレビューする。PoC自身のbaselineを維持することは、そのPoCを製品採用することを意味しない。#7の融合の採用保留は継続する。

Swiftのscorer/validator/keyword/融合/実storeテストに加え、Pythonは故意のRecall低下、negative false-hit増加、件数・欠損・NaNを失敗として検証する。index時間はレポートmetadataに残すが品質gateでは速度を比較しない。通常jobはMCP serialization/画像guard/UI検索を通らない。`baseline_native_vector` の全176順位とMCP vectorの一致は #7 の実モデル測定で確認済み。

**モデル更新時は実モデル job を実行する**。`search-model-evaluation.sh` は必ず `--refresh --live-queries --poc` を指定し、実CoreML query/doc生成、実MCP vector/keyword、同じPoC、索引・queryレイテンシを報告する。MCP2経路を含む7modeの`live-model-baseline.json`と比較し、通常jobの5mode baselineとは区別する。今回の集計は`live-model-measurement.json`に保存した。モデル未準備は失敗。通常CIが通っても実モデルの品質確認を代用しない。負荷を重ねず M3/M4 で計測する。GitHubの`workflow_dispatch → real_models=true`は、モデルとSwift6.4/Metalを用意した`self-hosted,macOS,ARM64,cc-search-models` runnerを要求する。runner環境の`CC_MODELS_DIR`が必須で、runner登録/モデル配置は自動で行わない。今回このjobのコマンドはローカルM3で実行し、hosted quality jobの実行と区別する。

baselineを変更する場合は理由・モデル/pipeline・分割・差分をレビューする。通常QAコマンドはbaselineを書き換えない。更新コマンドは明示的:

```sh
# 固定ベクトルを更新する場合だけ。合成cacheを指定する。
python3 evals/search/freeze-vectors.py /tmp/cc-live-search/coreml-vectors.json
python3 evals/search/generate.py
# 新契約runnerの出力から、理由を添えて品質baselineを更新。
python3 evals/search/freeze-quality.py /tmp/cc-search-quality/contract.json evals/search/golden-quality.json
```

fixture/モデルを変更する場合は `freeze-vectors.py` のpipelineの固定revisionも変更し、keyを推測して合わせない。別pipelineの評価は旧baselineを保持して品質差分を読む。
