# M3での保存遅延比較とquiet period採用（#10 / #1）

2026-10-15。M3 24GiB、macOS 27.0.1、AC、low-power 0。M4 32GBは使用していない。[計画](../plans/capture-stability.md)。主眼は実AppCoordinator/TriageWiring/Whisper/d1/CoreML/Vision/SQLiteを使うfixture replayで、実hotkey/mic/screen/toastとは区別する。

## 採用

Whisperのencoder/decoderともCPU+Neural Engineを維持する。製品の `LiveServices` で、captureが終わってからトリアージ再開まで750ms待つ。次のcaptureが始まったら待機中の古いresumeを取り消す。保存処理やトーストはこの待ち時間を挟まずに完了する。通知の順序と世代を照合し、wiringの解放時には生きたqueueを止めたままにしない。

新しいcaptureではmax-pauseの安全タイマーも更新する。resume/pauseは同じqueue actorの中でawaitを挟まず行い、待機workerは再びpausedの条件を確認する。これによりquiet period中の次の録音を、前の録音の180秒タイマーが再開してしまう窓を防ぐ。キャンセルを無視するsleep・再録音・連続quiet period・所有者解放・安全タイマー更新をテストした。

## 比較結果

同じモデル、音声、decoding条件を固定し、Releaseの1バイナリで計測する。候補選別は10音声×2条件。confirmは既存方式/候補をABBAAB順の各3passとし、最初の2passは全30音声、その後は10音声。モデル準備・初回推論は温間保存P90へ含めず別記し、condition順も反転した。計測中にこのタスクのbuild/testは行っていない。

| confirm順 | 設定 | 音声数/条件 | 並行保存 P90 ms | 平均CER | 保存→index通知 P90 ms | 性能gate |
|---|---|---:|---:|---:|---:|---|
| 1 | 既存 | 30 | 1983.3 | 7.72% | 41692.5 | 合格 |
| 2 | quiet 750ms | 30 | 1674.0 | 7.72% | 55663.7 | 合格 |
| 3 | quiet 750ms | 10 | 1740.7 | 7.97% | 18949.2 | 合格 |
| 4 | 既存 | 10 | 2004.6 | 7.97% | 13534.1 | 不達（並行P90） |
| 5 | 既存 | 10 | 1953.6 | 7.97% | 13595.6 | 合格 |
| 6 | quiet 750ms | 10 | 1673.4 | 7.97% | 18977.0 | 合格 |

候補は3passとも保存P90≤2秒、active physical≤10GB、d1解放後≤4GBを満たした。全30音声のCERは既存と同じ7.72%で、9%の品質条件内。既存方式は3pass中1passが2.005秒で不達。候補の各passのP90は1.67〜1.74秒だが、3passだけで全環境の保証はしない。

代償はburst中の整理待ちである。30件連続では保存→index通知P90が約14秒長くなり、10件連続でも約5.4秒長い。通知時刻はMainActorでeventを受け取った時刻で、推論開始/終了の精密な時刻ではない。単発captureでは再開前に750msを追加する。優先するのは即時保存で、索引は非同期のまま。恒常的な高速captureでは整理が後回しになるため、この挙動を実機受け入れで確認する。

### 不採用の構成と背景負荷

| 選別の構成 | 並行 P90 ms | 後回し P90 ms | 10音声CER |
|---|---:|---:|---:|
| encoder CPU+GPU | 10924.7 | 2603.4 | 9.44% |
| decoder CPU+GPU | 3796.4 | 3867.9 | 7.97% |
| 両方CPU+GPU + quiet750 | 1944.1 | 3433.3 | 8.39% |
| encoder CPU+GPU + quiet750 | 2173.4 | 1978.5 | 9.44% |

GPUへ移す案は両条件で安定した性能を示さず、encoderを移す案は10音声の品質条件も外れた。モデルやruntimeを切り替えない。computeUnitsはCPU/GPU/Neural Engineの使用を許可する構成で、専有や実行先の保証ではない。

一次screenの既存方式は並行4.47秒・後回し4.75秒だった。後のcontrolは1.56秒へ戻った。途中でload average 13.75と、mediaanalysisd等のOS背景処理による高CPUを観測した。memory_pressureのfree割合は76%で、M4/32GBを必要とするメモリ不足は観測していない。これらは観測点の情報で、背景処理がANE遅延の原因と確定したわけではない。quiet750でも最初のscreenは2.11秒で不達だった。所有アプリ内の競合を減らしても、OSの共有資源や外部負荷は隔離できない。

## 保存した証拠

[screen全4trial](../e2e/results/20261015-capture-stability/screen/summary.json)、[組み合わせ全3trial](../e2e/results/20261015-capture-stability/combinations/summary.json)、[confirm全6trial](../e2e/results/20261015-capture-stability/confirm/summary.json)。計13trial、340件すべての保存・最新世代索引・query key整合を実テストで確認した。各trialの不達gateを保持する。

raw reportは各summaryの `rawRelativePath` にgzipで保存し、`rawSHA256` は解凍した元JSONのhash。音声、画面、私的なDB本文を含まない。記録されるのは著作fixtureのID、CER、STT数値、レイテンシ、physical、thermal等。confirm/組み合わせには使用したtest executableのSHA256とload averageの前後を残した。screenのsourceはda82928、組み合わせのrunnerは80ceab3、confirmは安全タイマー更新後の39d515e。製品採用時の変更はLiveServicesで750msを指定する1行で、confirmでは同じ設定を明示的に渡している。

再現: Releaseを事前build後、`CC_MODELS_DIR=/path/to/models python3 scripts/capture-stability.py --phase confirm --candidate quiet-750 --output /fresh/output`。出力済みのフォルダを再利用せず、良いpassだけ採らない。

## 残件

#10のfixture安定性比較とアプリ内競合の対策は進んだ。実hotkey/mic/screen/toast、battery/low-power切替、高負荷時の製品policy接続と実機検証は未完了。helper導入は利益が証明されていないため保留する。#1の最新実機受け入れも未完了。[チェック表](../manual-tests/remaining-acceptance.md)を使う。#2はreadonlyで再確認して15件・手動正解0件で、採用/再処理を保留する。

検証: Release build成功、Appテスト99件成功（実モデルopt-in 1件skip）、比較scriptの契約4件・性能gate契約6件成功、13回の実モデルcaptureテスト成功。GPU構成・背景高負荷の不達は上記の通り保持している。
