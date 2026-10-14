# 日本語検索の最小ベースライン（#11 前半）

実施: 2026-10-14。データ: `search-ja-v1`、合成48記録/144クエリ、dev/holdout はtopic単位で分割。holdoutは正解あり64、正解なし8クエリ。製品と同じ固定Core ML revision、256次元、画像なしの注釈＋タイトル入力。実際の `MCPToolHandlers` と `SQLiteRecordStore` を使う。

| holdout 指標 | 現行ベクトル検索 | 現行部分一致 |
|---|---:|---:|
| Recall@3 | 0.9531 | 0.7188 |
| MRR（深さ30） | 0.9479 | 0.7240 |
| 正解なしの空結果率 | 0/8 | 8/8 |

モデルのquery推論を含む測定を `--live-queries --compute cpuAndGPU` で実施。現行cc-mcpの計算ユニットに合わせた基準線であり、アプリのANEの速度測定ではない。各3回、最初の呼び出しと以降のwarmを別集計。詳細・dataset hash・指標・測定内訳は `evals/search/baseline-quality.json`。

次のPoCではexact lookupと意味検索を両立する順位融合、短語/識別子、日本語正規化、正解なしの棄却を比較する。上記は新しい複数正解のRecall定義であり、旧PoCの0.933とは比較しない。

制約: 小さな合成topic集合。画像融合・実Vision OCR・匿名化した実利用分布は未検証。OCR/STTノイズは注釈の誤字を使った最小検証。データ全体を見て閾値を調整せずdevで固定しholdoutで採否を評価する。

検証: 指標の複数正解/重複/空結果、ground truth ID/grade、split漏れ、fixture pathの拒否の6テスト成功。生成manifestのsha256、一意な26文字ID、dev/holdoutのquery文字列の分離を確認。評価は一時DBで実行し、個人DBは開かない。

再現手順とライセンスは `evals/search/README.md`。#11は最小基盤まで実装し、画像fixture・品質CI・実モデルの専用実行は後続で拡張する。
