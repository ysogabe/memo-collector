# 日本語検索の固定評価セット

Refs #11。`search-ja-v1` は新規に執筆した合成データ48件と144クエリ。個人のDB・音声・スクリーンショットやDigUpの評価素材は使わない。生成データは CC0-1.0。生成コードと評価コードはリポジトリの扱いに従う。

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

指標の単体テストはモデル不要。品質のgolden baselineとCI判定、実モデルの専用実行、合成スクリーンショットの追加は後続PRで拡張する。ベクトルcacheだけのCIは推論ランタイムの回帰を保証しない。モデル切替は別cache/索引世代で評価する。
