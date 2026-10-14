# #10 / #1: 保存遅延の安定化比較

2026-10-15。main 37b4a91から専用worktree、`codex/capture-stability`。M3 24GiB / AC / low-power 0。M4 32GBは使用しない。既定DBは15件・手動正解0件をreadonlyで再確認し、#2の採用・再処理は行わない。

## 切り分け

前回の3passで並行triageの保存P90が1.608 / 1.763 / 2.340秒となり、最後のpassは性能gate不達。STTのwait/fallbackは0、encoder所要時間が増えた。熱・共有資源・背景負荷は未確定。

既存WhisperKitTranscriberのcompute設定を測定バンドルから指定し、CPU+Neural Engineの既定、encoderをCPU+GPU、decoderをCPU+GPUへ変えた候補を比較する。computeUnitsは使用を許可する先で、専有や実行先の保証ではない。モデル・音声・STT decoding条件は固定する。

加えて、保存後750msのquiet periodを候補にする。次のcaptureが始まれば古いresumeを取り消す。通知は直列化し、キャンセルを無視するsleepやwiringの解放もテストする。製品の既定は0msのまま。短い連続captureでは索引を遅らせるため、保存→indexイベント到着とburst後の全索引待ちも記録する。

## 測定

Release buildとモデルなしテストを先に完了し、計測中は他のbuild/testを走らせない。`scripts/capture-stability.py --phase screen` で各候補10件×2条件を逐次試す。各processの初回準備・温めは保存P90から分離する。condition順も反転し、各captureのthermalState・STT内訳・文字誤り率(CER)を数値で残す。fixtureだけを使い、実マイク・画面・個人DBへは書かない。

候補が改善を示したら `--phase confirm --candidate <name>`。baselineと候補をABBAAB順に各3pass。最初のbaseline/候補は全30fixture×2条件、その後は10件×2条件で継続安定性を確認する。全結果と不達gateを保持し、良いpassだけを採らない。

採用条件: warm保存P90≤2秒を各candidate passで確認し、30fixtureの平均CER≤9%と既存方式との品質差を評価する。active physical≤10GB、d1解放後≤4GB。CPU/wall・初回prepare・索引待ちの代償も確認する。単一passや未見ではない合成データだけで、実機受け入れの完了は宣言しない。実hotkey/mic/screen/toast、battery/low-powerの製品接続と実機検証は別に残す。

#10をhelperへ切り替える根拠にはしない。改善があれば必要な最小の設定だけを製品へ反映し、通常のアプリテスト・CI後に既存のマージ指示に従って統合する。完了後のworktreeは片付ける。

一次screenではGPUencoder単独の並行P90が10.9秒、quiet750msでも2.11秒で不達。OS背景処理の高CPUも観測したため、GPUのencoder/decoderとquietの組み合わせを追加して比較する。各trialのload averageと同じ測定バイナリのSHA256を残す。

## 到達点

13trial/340件の保存・索引は成功。confirmではquiet750が3passすべて1.67〜1.74秒、全30音声CER7.72%で通過し、製品に750msを指定した。GPU案は採用しない。索引の遅延と外部負荷による不達を残す。[結果と採否](../research/capture-stability-20261015.md)。
