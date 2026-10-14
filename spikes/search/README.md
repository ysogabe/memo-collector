# 日本語ハイブリッド検索 PoC（#7）

**判定: 製品への融合方式の採用は保留。** trigram と短語/厳密識別子を組み合わせる設計は候補になるが、今回のRRF/棄却設定はnDCGの採用基準を満たさなかった。現行Core ML/ベクトル検索を維持し、検索候補を切り替えない。

コードは製品とは独立した `evals/search/Runner/Sources/SearchPoC` と `cc-eval-search/PoCBenchmark.swift`。通常のDBは開かず、一時DBに合成データだけを投入する。

```zsh
swift test --package-path evals/search/Runner --disable-keychain
CC_SEARCH_EVAL_OUTPUT=/private/tmp/cc-search-poc scripts/eval-search.sh \
  --models /path/to/model-root --poc
```

初回はCore MLで文書/クエリを生成する。2回目以降はhash検証したcacheを利用する。新しいモデル/fixtureには別cache先か `--refresh`。ベクトルcacheを利用した検索時間はretrieval-onlyで、推論時間を含めた値ではない。実queryの測定には `--live-queries`、計算ユニットには `--compute` を指定する。

## 同じv2データでの比較

2026-10-14、合成48記録/176クエリ。holdoutは正解あり80/正解なし8、複数正解・段階的grade。深さ30、各3回。GRDBが使うSQLiteは3.54.0。Core MLの実モデルで生成した256dベクトルを使い、annotation+titleのみ（画像なし）。

| holdout | Recall@3 | MRR | nDCG@3 | 正解なし空結果率 | warm P95 ms |
|---|---:|---:|---:|---:|---:|
| 現行MCP vector | 0.9563 | 0.9583 | 0.8482 | 0/8 | 19.59 |
| 現行MCP 部分一致 | 0.7750 | 0.7792 | 0.6563 | 8/8 | 21.67 |
| 現行native vector | 0.9563 | 0.9583 | 0.8482 | 0/8 | 13.77 |
| unicode61 + 短語/識別子補完 | 0.6750 | 0.6792 | 0.5766 | 8/8 | 0.53 |
| trigram + 短語/識別子補完 | 0.7750 | 0.7792 | 0.6563 | 8/8 | 0.53 |
| RRF | 0.9500 | 0.9771 | 0.8247 | 0/8 | 19.82 |
| 棄却付き RRF | 0.9500 | 0.9771 | 0.8221 | 6/8 | 19.79 |

native と MCP の現行vectorは全176クエリの順位が一致することを確認した。MCP行はJSON生成などのハンドラ処理込み、native/PoC行は検索APIのみ。新方式と現行の速度差にはnative vector行を使い、MCPのoverheadをアルゴリズムの改善と呼ばない。#11前半のv1との違いには追加query/誤字修正があるため、v1の数字とはアルゴリズム比較しない。

## 条件と判断

- annotation/title/url/appを同じprojectionに持つ。NFKC＋小文字化し、濁点は落とさない。trigramの3文字未満は部分照合で補う。API名の境界、Issueの番号、URL全体は元のfieldで確認し、`#6`と`#60`や`API`と`APIToken`を区別する。
- 各retrievalに同じarchived条件を候補取得前から適用。sourceごと50候補、RRFのk=60。IDを重複除去し、rank scoreをcosine/確率として扱わない。
- 棄却はdevだけでcosine閾値0.20〜0.80を比較。`0.45 Recall@3 + 0.35 MRR + 0.20 空結果率`で0.65を選択し、holdoutでは固定。URL/#number/単独ASCII識別子はkeyword-onlyとする。単独の英単語を識別子とみなすこの簡易判定も、製品採用前に改善が必要。
- 棄却付きRRFのRecallは現行から0.6ポイント低下、MRRは1.9ポイント改善、nDCGは**2.6ポイント低下**。事前提案の「2ポイントを超える品質低下を避ける」を満たさない。正解なしも2/8誤ヒットが残る。holdoutを見て設定を調整し直さず、今回の設定を採用しない。
- 検索根拠はfieldと元文字列のUTF-16範囲/一致文字列。意味だけのヒットへ文字一致を捏造しない。`rankings.jsonl` はquery/ID/score/metric/根拠、`results.json` はsplit/tag別集計、環境/hash/パラメータ。

## 容量ベンチ

品質セットとは別に、同じ合成本文を複製した1千・1万件でkeywordを測定。先頭10query、warm各3回。重複本文なので品質の証拠にはしない。容量は共通projectionとunicode61/trigram **両方のFTS** を含む。

| 件数 | 索引時間 ms | DB bytes | keyword P50 ms | keyword P95 ms |
|---|---:|---:|---:|---:|
| 1,000 | 53.11 | 1,216,512 | 0.75 | 20.26 |
| 10,000 | 504.94 | 11,948,032 | 7.06 | 191.95 |

短語/識別子の全件補完と根拠生成の負荷が長いtailになる。製品導入では識別子の専用索引と候補絞り込みを先に改善する。この測定を新方式のend-to-end推論性能として扱わない。

## 制約・次の判断

合成小規模セット、画像融合・実Vision OCRは未検証。OCR/STTの誤字は注釈/queryで検証し、元画像のOCR本文は保存/外部公開しない。OCR追加時はguard済みprojectionとMCP excerptの契約が必要。DigUp型z/coverage融合は今回の必須比較には含めず、必要なら別のdev/holdoutで評価する。

現在のAPI境界候補は `QueryFixture` のtext/filterから、`RankedItem`（ContextRecord IDと順位score）と `Evidence`（field/元文字列範囲）を返す構成。製品共通SearchRequestへの接続は今回行わない。

検証: 指標/fixtureの6テストと、日本語長短語・#6/#60・URL・全角API・候補前archived filter・元の根拠範囲・RRF重複排除の3テストが成功。次は#9の条件付き保存と索引世代に進み、runtimeや検索の変更を安全に比較できる土台を作る。
