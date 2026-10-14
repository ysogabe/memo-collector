# #5 自己レビュー残件の対応

2026-10-14、M3 24GiB。#9の世代索引、#19のactual coordinator測定、#20のモデル検証に続く修正。

## 修正と根拠

- `TriageQueue.runIndex`の製品SQLite経路は#9でversion/generation/hash/keyを同じtransactionへCASし、編集時の古い結果を拒否する。`SearchGenerationTests`とstore generation/CAS testsで確認済み。non-versioned fakeの互換経路は製品DBの経路と区別する。
- `SearchIndexMaintainer`の製品generation再構築はSQLのmissing IDsを100件ずつ取得し、id取得のための全JSON decodeを使わない。短いwarmupは準備後にpending scanを一度だけ行う。初回compileが5秒を超える場合はguard/intentを先に再開し、準備後にindexを拾い直す。missing/failure、modelsPreparedの再試行、準備中の設定変更から古いstateをpublishしない分岐をテストした。
- 録音デバイスの張り直しが失敗した`Session.interrupted`を`RecordedAudio.wasInterrupted`で返す。認識できた途中の音声/注釈は保存し、extraと保存noticeで中断を伝える。画面収録の拒否も併せて表示する。中断後に発話を認識できなければ、通常の無音と区別して再録音を案内する。
- appとlegacy E2EのScreenshotEncoderをCCCaptureの一つの実装へ統合。順序WebP→HEIC→PNG、非可逆quality0.85は維持した。
- retryを同じidで一度だけ実行し、進行中のundo後に古い録音を復活させたり保存完了を通知したりしない。`.starting`中のhotkey reset、スクショ/音声書き込み失敗で残せる記録を保存する境界もテストした。
- HotKeyControllerのbackendを注入できるようにし、本物のキー登録をテストで行わずにreset→stop→shortcut→start→statusの順序、modifier変換、fallback/error/action、active時の不要なretryを確認する。
- ModelSlotsのunmanifested/ready/mismatchedとverify throw（大容量downloadを始めない）を確認。#20の契約と合わせた。
- 一時停止テストは200ms待って「何も起きない」を見る方式から、workerが実際にcapture境界でsuspendedになったeventを待つ方式へ変更。再開後の各step成功も確認する。
- [OCR切り分け手順](../manual-tests/ocr-regression.md)と、14著作fixtureに限定したhash/bbox診断を追加。本文/個人の画面は保存しない。

## E2Eの自動判定

正式な`e2e.sh`に(d) actual AppCoordinator/TriageWiringを追加した。legacy(a)は既存のモデル比較・CER/数値確認用に残す。キャプチャのpause/resumeはactual(d)で検証する。

```sh
CC_MODELS_DIR=/path/to/models CC_E2E_STEPS=d CC_PERF_ASSERT=1 scripts/e2e.sh
# actual app idle CPU/physicalの判定:
CC_MODELS_DIR=/path/to/models CC_E2E_STEPS=c CC_PERF_ASSERT=1 scripts/e2e.sh
```

`e2e-acceptance.py`は保存P90≤2000ms、capture physical≤10000MB、d1解放後≤4000MB、10件以上の保存/最新索引全件一致、実app idle CPU≤1%/physical≤4000MBを扱う。欠測、NaN、負数、boolean、0件、索引不一致、未準備モデルは成功にしない。Gateは6件のcontract testをCIで実行する。

fake recorderの開始時刻を本物のmic/hotkey≤150msへ読み替えず、toast時間とも区別する。過去の1.758秒passだけで安定達成としない。#10/#1の実機・複数passは別受け入れとして残す。`CC_PERF_ASSERT`は明示opt-inで、通常check.shに環境依存の性能判定を混ぜない。

## 検証

準備済みモデルを明示した全体`check.sh`、アプリ90件成功（実モデルopt-in 1件skip）とパッケージの実モデル/数値/検索/保存/ガード検証。14画面OCR診断はVision revision3で出力できた。performance gate 6件、shell構文、diff whitespaceを確認した。モデルと個人DBの書き換えはしていない。
