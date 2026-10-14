# ADR-0004: 永続 job 契約を採用し、helper の製品導入は保留

- 状態: 提案、2026-10-14。関連: #10 / #9。
- 根拠: [PoC/実測/制約](../../spikes/worker/README.md)。

## 決定

Record と job を同一transactionで保存し、version/generation/lease token を照合して結果を書き込む契約を採用候補とする。embeddingの世代と編集競合は #9 の製品実装で先行した。guard/intent/STT全体の scheduler と helper化は、このPoCだけでは採用しない。

text helperは障害を隔離し、停止しても保存済み48記録が残った。M3のwarm physical最大はhelper209.9MB / inline208.6MBで削減効果を確認できず、warm query P95は24.83 / 20.71ms。kill復旧7.98秒、hang停止138ms、親死亡時954msで終了した。実モデルと IPC、kill復旧、timeout、親終了を検証できた。一方、起動には数秒以上のモデルprepareが必要で、IPCの温間遅延と総メモリにも費用がある。Whisper/d1の実アプリ総メモリやUI応答性を、embeddingだけの結果から保証できない。

## 採用の条件

1. M1のhotkey→保存toast p90を既存方式から悪化させない。新着の保存がhelper起動やbackfillを待たない。
2. 同じReleaseアプリ・同じモデル/入力で、親子合計physical footprint/RSSとpowerを比較。STT/d1との競合、low power/battery/high loadで新着優先とbackfill遅延を実測する。
3. #9のSQLiteRecordStoreへhelperのsigned結果をCASで保存し、guard済みMCP出力、再起動後の全step回復、コード署名/配布、sandbox、キャンセルをE2Eで確認する。
4. Process/JSON-lines とXPCは別候補。今回XPCは実装していない。仕様が増える前に、必要な処理だけ分離して利益を確認する。

## STT前保存の扱い

現在はSTT後にRecordを作り、noSpeechを保存しない。STT前のdurable captureはクラッシュ耐性を上げるが、暫定Record/音声保持/noSpeech削除/回復UIが必要になる別の変更である。今回のPoCは合成text Recordを先に保存する契約を示すもので、製品の録音保存順を変更していない。現行と同じ挙動を保ったまま、まずSTT後→triage前の全step job化を別PRでレビューする。
