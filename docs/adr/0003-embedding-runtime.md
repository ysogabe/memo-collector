# ADR-0003: Core ML を維持し、llama.cpp は比較経路として残す

- 状態: 提案、2026-10-14。
- 関連: #8、#9。[再現手順と条件差](../../spikes/llama/README.md)、[測定結果](../../spikes/llama/results.json)。

## 決定

製品の Core ML は維持する。llama.cpp / Metal への全面置換は採用しない。小さな query-only helper や native batch は候補として残す。実測の速度優位は量子化・ハーネス・前処理も異なる条件での値であり、M3のReleaseと電力を追加測定しても全面置換の利益は確認できない。M4 32GBはユーザー指定により対象外で、採用条件にしない。

## 根拠

M3 24 GiB の同じ合成入力で、llama Q8_0 と Core ML GPU の 768d コサインは query 最小 0.99959、文書最小 0.99989、画像最小 0.99936、短い融合最小 0.99954。224 件の text token ID は一致したが、画像 RGB hash は一致しない。近い方向のベクトルであっても同一 pipeline と見なさない。

256d 検索の holdout Recall@3 は Core ML GPU/ANE 0.95625、llama 0.95。MRR は 0.95833 / 0.95729、nDCG@3 は 0.84823 / 0.84352。今回の小さな set では差は小さいが、4 枚だけの画像/融合から全利用状況での互換性は判断できない。

Core ML ANE の温間 query は GPU より速く、既存アプリ経路を維持する根拠がある。native の起動と sequence packing には改善が見られたため、検索 helper は次の検証候補とする。query-only の peak physical は native 221 MB / Core ML GPU 390 MB だが、before の差を引くと約218 / 237 MBであり、ハーネスの基底差が大きい。完全な初回Core MLコンパイルは未測定で、OS cacheは消していない。[main統合後のRelease/電力/actual coordinator測定](../research/post-merge-runtime-validation.md)では温間query P95がANE 5.12ms / native 12.60ms、全処理区間22.62 / 35.08秒だった。GPU/ANE powerとGPU residencyを採取したが、ANE利用率はOSから提供されない。SoC電力は背景負荷を含み、ハーネスや精度差からruntime単体の消費を分離していない。

## 再索引と採用条件

runtime / quantization / preprocessing の変更は #9 の `EmbeddingPipeline.compatibilityKey` を変え、**新 generation を shadow 再構築**する。旧ベクトルとの混在や単なる pointer 更新は認めない。比較用 llama の 768d をそのまま現在の 256d に保存しない。query/doc の key、MRL、正規化を同じ設定で実装する。

再構築費用は件数×文書/画像/融合の実測時間に加え、追加 256d Float32 vector と jobs の DB 領域、旧世代保持分。今回の text-only 48 件の時間を画像主体の全データへ外挿しない。容量と時間は採用候補の実データ件数/入力種別から見積もる。進行中の編集は version CAS で棄却し、generation が全件最新になってから切り替える。

採用する変更は別 PR とする。Release の実アプリで capture P95 を悪化させず、検索品質の低下 2pp 以内、正解なしの誤検出を悪化させず、総 footprint と電力を改善すること。長文・色管理・透明画像・融合の cap と位置を確認し、M3で同条件の結果を添える。M4は前提にしない。現時点はベンチマークを残す段階で、製品の推論や MCP compute units は変更しない。
