# 検索品質回帰評価の結果 (#11)

2026-10-14、M3 24 GiB / macOS 27.0.1 / Swift6.4 Debug。合成 `search-ja-v2`（48記録、176 query）を使用。コードは専用 worktree の stacked PR に分け、製品の検索融合・推論runtime・helper配置は採用しない。

## 実施した確認

- `scripts/search-quality.sh`: Swift12 test（metrics/validation/keyword/fusion/実store CAS・世代・削除）+ Python7 gate test、fixture SHA/再生成、実SQLite/vDSP/FTS5による5 modeの176 query実行、品質gateが成功。
- `scripts/search-model-evaluation.sh`: 実CoreML文書/queryを再生成、実MCP vector/keywordと同じPoCの7 modeを実行し、品質gateが成功。結果は [live-model-measurement.json](../../evals/search/live-model-measurement.json)、品質基準は `live-model-baseline.json`。
- モデル未配置の専用rootでは失敗。フェイク推論/keyword fallbackをvector評価の合格と扱わない。
- model-free CIは `golden-quality.json` を使用し、実モデルの結果とは別に固定。全てのbaseline更新は明示コマンドとレビューが必要。

## 今回の holdout（正例80 + 負例8）

| mode | Recall@3 | MRR(depth30) | nDCG@3 | 正解なし空結果 |
|---|---:|---:|---:|---:|
| current vector / MCP + native | 0.95625 | 0.95833 | 0.84823 | 0/8 |
| current MCP keyword | 0.775 | 0.77917 | 0.65632 | 8/8 |
| unicode61 + fallback | 0.675 | 0.67917 | 0.57665 | 8/8 |
| trigram + short/exact | 0.775 | 0.77917 | 0.65632 | 8/8 |
| RRF | 0.95 | 0.97708 | 0.82468 | 0/8 |
| gated RRF (dev threshold0.65) | 0.95 | 0.97708 | 0.82214 | 6/8 |

実query推論込みMCP vector warm P95 65.80ms、MCP keyword21.65ms、固定queryベクトルを使うnative vector12.86ms。scopeが違うのでnativeとの単純な差をIPC費用としない。索引/準備/容量、Recall@1/10、タグ別値は測定JSONに記録。環境依存の速度はCI品質gateから除外した。

## 実施範囲と運用

品質低下2pp、負例誤検出増加0を初期gateとして固定。既存意図分類issueの評価は変更しない。dev/holdoutはtopic単位で隔離され、全ての正解ContextRecord IDが固定されている。

このcorpusのOCR/STT誤りは合成注釈の誤字。Vision OCR認識、実スクリーンショットの分布、録音、UI検索、MCPの画像guardはこの品質gateの対象外。model-free jobは推論runtimeの更新を検知できないので、モデル変更時には実モデルjobの実行が必要。

GitHub hostedのjobはSwift6.4を必要とするpinned manifestsのためXcode27 previewを使用する。実モデルjobはモデルを用意したself-hosted macOS runnerが必要で、登録やモデルdownloadは自動化していない。今回そのコマンドをローカルM3で通した。GitHub実行結果はPRのChecksで確認する。
