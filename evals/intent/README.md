# 意図分類の実データ評価（#2）

`cc-models eval-intent` は既存DBをGRDBのreadonly接続で読み、migration・モデル取得・添付読み出し・レコード更新を行わない。`triage.model == "user"` で意図が設定され、注釈が空でない記録だけを正解にする。公式開発fixtureは除く。モデルが付けた意図を正解へ流用しない。

## 実行

```bash
swift build --package-path Packages/ContextCaptureKit --product cc-models
bin=$(swift build --package-path Packages/ContextCaptureKit --show-bin-path)
"$bin/cc-models" eval-intent --table --output /tmp/intent-stored.json
# 別DBは --database /path/to/ContextCapture.sqlite
# 質問文を比較するときだけ、準備済みモデルを指定する。
CC_MODELS_DIR=/path/to/models "$bin/cc-models" eval-intent \
  --candidate evals/intent/question-ja.json --thresholds 0.5,0.6,0.7,0.8,0.9 \
  --table --output /tmp/intent-candidates.json
"$bin/cc-models" eval-intent --print-question > /tmp/product-question.json
```

手動修正後も元の確率を保持する。修正前の古い実装で確率が消えた記録は、再推論で比較する。

保存済み確率を必ず集計し、`--recompute` または `--candidate` があれば製品質問文を再推論して基準にする。候補は `name`、`instructions`、全5意図の `descriptions` を持つJSON。`product` は予約名。ラベル順は製品と同じに固定する。再推論は製品と同じ特殊トークン除去・600文字制限を通し、意図のみ1 forwardする。

DB順は撮影日時・ID。確率の欠落を除く前に最初の80%をdevelopment、最後の20%をholdoutに固定する。5件未満はdevelopmentだけ。外部JSONの順は入力者が固定する。holdoutで候補・しきい値を選び直さず、developmentで選んだ案を一度検証する。各setのgoldCountsと混同行列で、少数クラス・note/researchの取り違えも確認する。

`coverage = 分類された件数 / 評価件数`、`accuracy = 正しい件数 / 分類された件数`。未分類を混同行列の別列に含め、分類0件のaccuracyは表で「—」、JSONで省略する。欠落確率は `missingStoredProbabilities` に出す。欠落・不正な5クラス分布は成功の精度に混ぜない。不正分布はエラー、正解0件は `needs_manual_labels` のレポートと終了コード2。確率が全件欠落なら精度表は空なので、その状態で採用を判断しない。

集計には注釈やIDを出力しない。DB・入力ファイル・既定のアプリデータ領域へレポートを上書きできない。保存済み確率の元モデル/質問文は不明な場合があるため、候補との差を判断するときは再推論したproductとの比較を使う。再推論の集計には実モデルのconfig/weights SHA256と候補SHA256を残す。モデルidentifierはコードが想定する版で、hashを併記して実ファイルを区別する。

## 外部の正解データ

`--input` で次の形式を読める。例は合成データなので `kind: synthetic` とする。実際に手動で正解を付けたデータだけ `manual` を使う。`id` は一意、`truth` は5意図のいずれか。保存済み確率を持たない行は再推論に使える。

```json
{"kind":"synthetic","samples":[
  {"id":"example-1","text":"この関数のテストを書いて","truth":"code",
   "probabilities":{"todo":0.05,"research":0.05,"code":0.8,"note":0.05,"schedule":0.05}}
]}
```

## 採用までの残件

Inboxでユーザーの意図に合わせて30〜50件を手動修正する。文章・意図の偏りと正解の一貫性を確認した上で、developmentの分類率と正解率の両方から案を選ぶ。holdoutで現行より悪化していないか確認し、PRD §8.1 と `D1Questions.intent` / `Intent.confidenceThreshold` を同じPRで更新する。採用後にintent stepだけを再処理し、`model == "user"` の正解を上書きしないことを確認する。

`labelCountSufficient` は実ラベル30件以上という必要条件だけを示す。自動採用や再処理を行わない。M4 32GBは必要ない。日本語候補は比較対象で、未採用。

## ツールの実モデル検証（2026-10-14）

M3 24GiB / macOS 27.0.1 / d1 MLX q8。[30件の合成データ集計](fixture-comparison-m3.json)。既存 `poc/fixtures/dataset.json` の順で24件/6件に分割した。しきい値0.7のdevelopmentでは、productのcoverage 79.2% / accuracy 84.2%、日本語候補は83.3% / 95.0%。6件のholdoutではどちらも83.3% / 100%。

これはCLIの実行確認であり、既にPoCで使われたfixtureなので、未見の実データ評価は成立しない。名詞だけの実メモの問題が改善した証拠にはしない。既定DBは15件・手動ラベル0件だったため、採用は保留して #2 をopenにする。製品質問文候補の1 forwardが既存classifyの意図確率と一致することも実d1で確認した。
