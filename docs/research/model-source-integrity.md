# #3 モデル供給網・準備状態・開発fixtureのフォローアップ

2026-10-14、main 43bd506から修正。M3 24GiB、M4 32GBは対象外。

## モデルの検証

EmbeddingModelPreparerは、manifestのない`.mlmodelc`をhashして正規モデルとして採用しない。以前の「copied table/tokenizerが合えば同じsourceからcompileしたと仮定する」経路を廃止した。固定revisionの11 sourceファイル（text/vision mlpackage含む）のpath/size/hashをmanifestへ追跡し、compiledファイルのhashと併せて検証する。古いadopted manifestのcopied sourceだけの履歴はmismatchedになる。全sourceの履歴を持つ既存manifestは再利用できる。

元mlpackage一式が手元にあればhash検証後に再compileし、なければ固定revisionから取得する。未検証compiledファイルを読んで推論したり、manifestで署名し直したりしない。作業途中で失敗したら既存destinationを保持し、HFのsymlink snapshotも元ファイルの実sizeを記録する。手順版はembeddinggemma-2-coreml/2。

D1ModelPreparerはcheckpointだけでなくconfig.json、tokenizer.json、tokenizer_config.json、chat_template.jinja、LICENSEの全6ファイルをMLX loadやdestination作成の前に検証する。metadataの固定SHA256は[LiquidAI/d1-3Bの固定commit](https://huggingface.co/LiquidAI/d1-3B/tree/051bcc464b01b9f92942b364d9586b0ef5912432)のresolveから取得したbytesで確認し、元checkpointは既存の固定LFS SHA256を維持。変換manifestのsource欄には全入力hashを残す。

開発用`CC_MODELS_DIR`の既存unmanifestedモデルをアプリのModelSlotsが読み取り専用で使う扱いは維持する。これは明示的な開発用モデル指定の既存契約であり、preparerで未検証compiledモデルをmanifestへ採用する経路とは別。個人のモデル置き場や共有HF cacheには、このテストで書き込んでいない。

## 準備中と失敗の扱い

- Whisperの起動warmupを待つ間、検索モデルがあるなら「準備中」を表示する。モデルが無い場合は「未準備」のまま。WhisperとembeddingのANE warmupは引き続き直列にする。
- ModelSlotsのverifyがthrowしたら、その原因を返す。壊れたmanifestをmissingへ置き換えて数GBのdownloadを始めない。
- TriageQueueがcapture pauseの上限180秒から自動再開したら、triageカテゴリへnoticeを記録する。注釈本文は記録しない。

## 開発データの投入

```sh
# 入力は既存の著作したtext-only corpus。data-dirとinputは必須。
swift run --package-path Packages/ContextCaptureKit cc-models seed-fixtures \
  --data-dir /tmp/context-capture-development --input evals/search/records.json
```

既定/設定済みのデータrootとは別の開発rootを明示する。入力をすべてdecodeしてからSQLiteの一つのtransactionへ投入する。重複等で失敗したら全件rollback。媒体はコピーせず、媒体pathを持つ入力は拒否する。各記録のextra.dev_fixture=trueで実データと識別する。

## 検証

- CCModelsTests: 41件、通常実行時4件skip（network/slow/明示source検証）。別のCC_RUN_SOURCE_VERIFY=1実行では、手元の固定d1 snapshot全入力hashも確認した。
- 正しいcopied filesだけを持つ未知compiledモデルの採用拒否、旧不完全manifest拒否、metadata同size改変を変換前に拒否、既存destination保持、HF symlink size、実embedding snapshotから再compile。
- DevelopmentFixtureTests 2件: 重複rollback、媒体拒否・fixture marker。TriagePauseTests 6件。アプリ76件成功、実モデルopt-in 1件skip。
- `scripts/check.sh`の対象filter実行成功。CLIで48件投入し、再投入の拒否後も48件、既定の本番rootへの拒否を確認した。

#5の追加テスト/録音中断/E2E性能gateと、#2の実データ評価は別成果とする。
