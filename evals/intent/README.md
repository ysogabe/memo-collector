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

集計には注釈やIDを出力しない。DB・入力ファイル・アプリのデータ/モデル領域へレポートを上書きできない。`CC_MODELS_DIR` で別にした開発モデルも保護する。保存済み確率の元モデル/質問文は不明な場合があるため、候補との差を判断するときは再推論したproductとの比較を使う。再推論の集計には実モデルのconfig/weights SHA256と候補SHA256を残す。モデルidentifierはコードが想定する版で、hashを併記して実ファイルを区別する。

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

## 2026-10-15の採用基準変更

ユーザー判断で製品の既定しきい値を0.7から0.6へ変更した。実マイク20件の保存済み確率ではtodo19件・未分類1件となる（2表記の反復であり、独立した20件の精度評価ではない）。質問文の候補は未採用。新規推論・再分類に適用し、既存DBの意図や手動ラベルは一括更新しない。#2の30〜50件の多様な手動正解による品質評価・既存記録の再処理は継続する。[採否と回帰比較](../../docs/research/mvp-acceptance-20261015.md)。上記の0.7の比較値は変更前の結果として保持する。

## 既存の自動意図だけを再推論する保守CLI

`cc-models reprocess-intents` は既定で読み取り専用のpreview。既存の `ContextCapture.sqlite` を検査し、全件数・手動件数・再推論対象数・現在の意図件数だけを出す。ID・注釈・URL・添付パスは出力しない。DBの新規作成・migration・添付参照・モデル読込・ダウンロードを行わない。`--data-root` と `--models-root` で対象を明示できる。省略時は `CC_DATA_DIR` / `CC_MODELS_DIR` と通常の既定値を使う。別名のSQLiteを対象として自動作成することはない。

```bash
"$bin/cc-models" reprocess-intents --data-root /path/to/data \
  --dry-run --output /tmp/intent-preview-new.json
```

再推論対象は、自動triageが既にある・注釈が空でない・公式開発fixtureではない記録。手動 `model == "user"`、未処理、空注釈は件数を分けて除く。対象の保存済み5クラス確率から、0.7/0.6それぞれの分類件数と分類が変わる件数も出す。これは同じ保存済み分布に対するしきい値の比較であり、正解ラベルを使うaccuracyではない。確率の欠落・不正分布はそれぞれ別件数とする。今回の再推論結果との一致も保証しない。

実際に更新する場合は、録音を終え、ContextCaptureアプリを終了してから実行する。外部CLIのd1とアプリの録音/STTの間では、アプリ内のcapture pauseは共有されない。これは録音中に実行しない保守コマンドであり、自動バックグラウンド処理用ではない。

```bash
# アプリ終了後。全出力先は既存ファイルと重ならない新しい名前にする。
"$bin/cc-models" reprocess-intents --data-root /path/to/data \
  --models-root /path/to/models --apply \
  --backup /path/to/private-backups/before-intents-20261015.sqlite \
  --output /tmp/intent-applied-new.json
# 終了コードとJSONのstatus・failed・skippedを確認後、アプリを再起動する。
```

`--apply` と `--backup` は両方必要。事前に準備済みd1のmanifest/checksumと読込を検証し、不足モデルは取得せず失敗する。更新前にGRDBのSQLite backup APIでWALのcommit済みデータを含む整合バックアップを作り、`quick_check` を確認する。バックアップは新規ファイルのみ、権限0600。親ディレクトリは事前に用意する。バックアップ・集計出力はデータ/モデル領域や互いの出力先を保護し、既存ファイルを上書きしない。

更新は既存の `TriageQueue.reprocess(id:steps:[.intent])` を使い、製品の質問文と0.6基準でd1を再推論する。STT・guard・indexは実行しない。32件以下のbatchでイベントを購読するので、256件bufferの超過で結果件数を取りこぼさない。手動意図は処理開始時と書込時に保護し、推論中の注釈変更は結果を捨てる。削除や推論失敗でも元の意図を壊さない。保存は最新行を読むIMMEDIATE transaction内で、`triage` と検索用の `intent` / `has_triage` だけを書き換える。未知のJSONフィールド、その他の記録内容、schema・input version・generation・jobs・現在のvectorは保持する。

レポートは `succeeded`、理由別の `skipped`、`failed`、結果が変化した `changedResults`、意図ラベル自体が変化した `changedClassifications` を区別する。`succeeded` は書込成功件数なので、同じ分類に再推論された件数も含む。推論失敗・未準備・注釈変更などで対象が完了しなければ `partial_failure` と終了コード2を返す。処理中の手動変更・削除は安全な除外として報告する。

この保守CLIの追加や再処理の成功は、意図分類の実データ品質評価の完了を意味しない。多様な30〜50件の本人手動正解とholdout比較は未達のため、#2は閉じない。質問文の候補も引き続き未採用。

合成データだけでの契約テスト:

```bash
swift test --package-path Packages/ContextCaptureKit --filter 'IntentMaintenanceTests|IntentOnlyReprocessingTests'
CC_INTENT_EVAL_BINARY="$bin/cc-models" python3 -m unittest discover \
  -s scripts/tests -p test_intent_reprocessing_cli.py
```
