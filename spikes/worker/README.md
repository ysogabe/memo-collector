# 推論 helper / 永続キュー PoC (#10)

製品へ導入しない隔離検証。`cc-query-worker` は実 CoreMLEmbedder を使う text-only JSON-lines executable。`Queue` は合成記録だけを temporary SQLite へ保存する。fault 用 fake worker は transport test に限定し、実測には使用しない。

```sh
python3 -m unittest discover -s spikes/worker -p 'test_*.py' -v
CC_MODELS_DIR=/path/to/prepared/models spikes/worker/run.sh
```

macOS / Swift / Python 3、既存 Core ML モデルが必要。出力は `results.json`（合成データの集計）、重み・個人 DB は読み込まない。今回の実測はM3 24GiB。M4 32GBはユーザー指定により対象外。M1はmilestone 1「録って残す」を指す。単独で実行し、他の推論/ビルドと重ねない。

## 現行ソースと基準

- `AppCoordinator.save` は screenshot encode と STT を並行し、STT 後に添付を書いて Record を insert。STT失敗時は空 annotation と音声を保存、noSpeech 時は保存しない。**STT完了前のプロセス死亡は現在も未保存となる**。
- `TriageWiring` は Record 保存直後に enqueue、capture中は次の triage step を開始しない。d1 は idle10分で unload。CoreMLEmbedder は actor + utility serial queue + autoreleasepool、SwitchableEmbedder は旧 model を unload。
- 既存 [3モデル同時の実測](../../docs/e2e/report.md)（2026-10-11、今回の新計測ではない）: paced capture p90 1.80秒、連続 capture 4.38秒、MLX cache256MBで peak約4.1GB。Whisper/d1 の支配的な使用量を text helper の数百MB削減から推定しない。
- main統合後にactual coordinator / TriageWiringのRelease fixture試験と3モデルの同時測定を追加した。[追加結果](../../docs/research/post-merge-runtime-validation.md)。MainActorの待ちは測ったが、実機hotkey→toastとbattery/low-power切替は未実施。`scripts/e2e.sh` / `docs/manual-tests/m1.md` が追加検証入口。PoC の保存時間は音声/スクショ/STTを含まない。

## 保存と状態遷移

```text
Record + jobs を BEGIN IMMEDIATE で永続化
pending → running(lease + token) → succeeded
                  └ failure → retry_wait(exponential backoff) → running
                                         └ max3 attempts → failed
edit/cancel → cancelled / 新 version job
lease expiry → 再claim（古い token は保存不可）
delete → jobs/results FK cascade
```

jobの主キーは record/step/generation/version。guard/intent/embedding を独立管理し、部分成功を保持する。claim/completion は同じ write transaction で入力version・lease token・deadline・generationを照合。vector256d/有限値/L2も検証する。検索は current record version と matching generation の結果だけを見る。今回の PoC 入力版は textのみで、製品のタイトル/画像入力版は #9 が担当する。

**single scheduler** を想定。複数接続から live lease を重複取得しないテストはあるが、分散 worker pool、依存 step の実ガード、モデル切替の全世代schedulerを実装したものではない。guard/intent は状態遷移を合成 payload で確認し、実 Whisper/d1 を helper化していない。

## 障害とリソース policy

15 test: Record/jobsの原子的保存、重複排除、再起動lease回復、期限切れ・編集後の古い結果拒否、部分成功、最大3試行とbackoff、キャンセル/削除、モデル世代、NaN/shape、IPC corruption、worker exit/hang、再起動上限。親は startup/request deadline と64KiB response cap、workerは16KiB request cap。helperは parent PID変更を1秒timerで検知して終了する。明示的 `crash` / `hang` は **このPoCだけ**の障害注入操作。

`Policy(capturing=True)` は次の処理開始を停止。low_power / battery / high_load は backfill(priority10)だけ遅延、新着(priority0)を優先。これらの注入policyのテストは通過しているが、macOS通知接続や実バッテリー上の電力低減は未測定。実装候補では `ProcessInfo.isLowPowerModeEnabled` / thermalState、IOKit電源情報を購読し、キューへpolicyを渡す。

同期 Python client が UI event loop の応答性を保証するわけではない。製品化時は actor/非同期IPCとキャンセルを適合させ、即時保存の critical path から model準備・IPC待ちを外す。

## 実測の範囲

[results.json](results.json) は同じ Swift executable/API の in-process harness と helperを比較する。inlineは推論が Swift benchmark host 内、helperは Python parent + Swift child。アプリ/Whisper/d1 を載せていないのでアプリの総RSS比較ではない。親/子合計のsampled RSSと、各 footprintを別々に報告する。

実モデル E2E: 48記録 + job を worker起動前に保存 → document推論 → version CAS → current generation検索。途中編集を1件挟み、旧結果拒否を確認。queryのinline/helper vector cosine一致、実helper kill/recovery、hang期限、parent死亡時の終了を確認する。

初回新binaryのprepareと cacheあり再起動は違う。最初のhelper起動と後のinline loadを、そのまま同条件cold比較としない。restore時間はkill後の次のqueryまで（起動 + prepare + inference）。各query3回のうち2〜3回目をwarm P50/P95とする。

M3 の今回の値: text-only 合成 Record+job 保存 P95 0.129ms（48件）、helper warm query P95 24.83ms / inline 20.71ms（各32観測）、warm physical最大 helper209.9MB / inline208.6MB。親/子合計sampled RSS最大1,853MB、Python親peakRSS24.1MB。RSSとphysicalの差が大きく、メモリの削減効果は確認できない。kill後復旧7.98秒、hang検知+kill138ms、親死亡後watch終了954ms。初回helper prepare12.81秒、後のinline7.85秒はcache順序が違うためcold速度優位の根拠にはしない。
