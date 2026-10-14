# main マージ後の実モデル検証（#8 / #10）

2026-10-14、PR #12〜#18 を順に main へ merge commit で統合した。測定時のmain は `3b70228968c0e7892ab5f589feeb030552374eb9`。[検索回帰CI](https://github.com/ysogabe/memo-collector/actions/runs/38559741457) は成功。#6/#7/#9/#11 は完了し、#8/#10 の追加測定を以下に記録する。

**測定対象は M3 24GiB。M4 32GB はユーザー指定により対象外で、タスクや採用の前提条件にしない。** 本文の M1 は CPU 名ではなく、milestone 1「録って残す」を指す。

## 結論

Core ML / ANE を維持する。Release でも ANE の温間 query P95 は 5.12ms、llama.cpp / Metal は 12.60ms。ANE の full workload は 22.62秒で、GPU 39.10秒、native 35.08秒より短かった。品質は従来測定と一致した。llama の採用には pipeline の切替と再索引が必要であり、この比較から全面置換の利益は確認できない。

helper の製品導入は引き続き保留。既存 PoC は障害回復を確認できたがメモリ削減を示さず、今回の actual coordinator の測定でも、3モデルを同居させた経路で20件すべてを保存・索引できた。新しい製品 scheduler や録音の保存順は変更していない。

## 環境・再現

- Apple M3 / 24GiB、macOS 27.0.1（26A434）、Swift 6.4。AC接続、battery 80%、lowpowermode 0。電源設定の変更なし。
- 両 runtime の Swift と native C/C++ は Release。アプリソースは hostless Release XCTest bundle に直接コンパイルした。Core ML、WhisperKit、d1 と実 SQLite を使う。
- 固定モデルrevision・GGUF SHA256・prompt/pooling/precisionの差は [runtime比較](../../spikes/llama/README.md)。取得済みcompile cacheを使用し、OS cacheの消去やモデル再取得はしていない。新process load と完全初回compileを区別する。
- [capture-model-evaluation.sh](../../scripts/capture-model-evaluation.sh) は build と test を分離できる。実際のモデルが無い/skip/古い測定ファイルの場合は成功扱いにしない。
- [power手順](../../spikes/power/README.md) と `runtime_workload.py` は事前build後に逐次実行する。powermetricsだけを管理者権限で採取し、workloadは通常ユーザー。生ログ・重みはGitへ入れず、集計にraw SHA256を残した。

## Release の runtime 構成比較

同じ合成48文書、176 query、4画像、4融合（計232入力）を各3回、続いて176 queryのbatch。P50/P95は2〜3回目。画像/融合の温間観測は各8件で、尾部の推定は弱い。[全集計・品質・ベクトル一致](../../spikes/llama/results-release.json)。

| 構成 | 新process load ms | query P50 / P95 ms | image P50 ms | peak physical MB | 176 query batch ms |
|---|---:|---:|---:|---:|---:|
| Core ML GPU | 12,066 | 12.77 / 15.10 | 536.64 | 690.5 | 2,342（逐次） |
| Core ML ANE | 5,051 | 4.99 / 5.12 | 524.60 | 308.9 | 885（逐次） |
| llama Metal Q8_0 | 1,171 | 8.13 / 12.60 | 995.52 | 892.5 | 1,045（packing） |

XCTestの開始時physicalは149.3MB、nativeは2.95MB。peakにはハーネスを含む。loadの順序はGPU→ANE→nativeでcacheの影響があり、完全な初回起動の優劣ではない。

holdout正例80 queryの256d評価は、Core ML GPU/ANEが Recall@3 **0.95625** / MRR **0.958333** / nDCG@3 **0.848232**、nativeが **0.95000 / 0.957292 / 0.843519**。以前のDebug比較と一致。Core ML fp16とQ8_0の元重みのbyte一致は未証明で、resize後画像hashも一致しない。純粋な同一重みruntime比較にはしない。768d出力の正規化・finite・件数も集計時に検査した。

### 電力・利用状況

[240 sampleの集計](../../spikes/power/results-runtime-release.json)。全process区間にはprepare、推論、batch、JSON保存、終了を含む。interval全体がphaseの1秒margin内に入るsampleだけを使い、下表のJは採取できた秒数だけの積分である。

| 区間 | wall / sampled秒 | CPU / GPU / ANE 平均W | GPU HW active residency | CPU+GPU+ANE 推定J（sampled区間） |
|---|---:|---:|---:|---:|
| idle | 10.01 / 7.09 | 2.683 / 0.084 / 0.000 | 8.96% | 19.60 |
| Core ML GPU | 39.10 / 36.44 | 4.919 / 4.008 / 0.000 | 67.59% | 325.27 |
| Core ML ANE | 22.62 / 20.25 | 3.382 / 0.152 / 3.207 | 12.23% | 136.50 |
| llama Metal | 35.08 / 31.42 | 2.054 / 3.633 / 0.000 | 97.50% | 178.71 |

SoC全体の推定値で背景負荷を含み、アプリ専用のenergyではない。nativeのCPU平均がidleより小さいことも、背景負荷が一定ではないことを示す。短いidle差分をアプリの消費電力へ換算しない。CPU process秒は GPU **20.60s** / ANE **5.60s** / native **2.57s**、GPU residencyはOSのcounter。**ANE利用率はこのOSでは未提供**。ANE Powerを利用率へ読み替えない。processor/GPU sectionのGPU Powerは別counterとして保持した。

## Actual coordinator の capture → durable save → triage → query

[測定結果](../e2e/results/20261014-m3-capture-release.json)。実際の `AppCoordinator` / `TriageWiring` のpause/resumeと、本物のWhisper/d1/CoreML/Vision/SQLiteを通す。ホットキー・録音器・前面コンテキストだけは著作したfixtureの再生。個人DB・マイク・画面は使用しない。10件ずつ、押下時間350msを再現したが、音声の長さは既存fixtureのまま。

| 条件 | 解放→保存 P50 / P90 / P95 ms | MainActor wake P95 / max ms | capture physical peak MB | 保存 / 索引 |
|---|---:|---:|---:|---:|
| triage後回し | 1,434 / 1,544 / 1,556 | 20.09 / 22.30 | 3,726.5 | 10 / 10 |
| triage並行 | 1,641 / 1,758 / 1,760 | 20.11 / 23.36 | 3,936.0 | 10 / 10 |

triage並行では9回の押下時にqueueがbusyだった。記録のdurable存在と添付path、最新generationの未索引0件、同じkeyで全10件を検索できることをassertした。MainActorの16ms wake intervalはscheduler遅延の代理指標で、UIフレーム時間や保存toastの測定ではない。fake recorderの開始時間を実マイクの開始速度に読み替えない。

Whisper準備5.64秒、Core ML準備4.72秒、d1ロード2.13秒、fixtureの初回STT1.55秒を温間captureと分離した。lifetime peak physicalは**3.94GB**。d1解放後2.55GB、embedding解放後1.15GB（Whisperは残る）。RSSのlifetime peakは2.94GBで、physicalと別指標として残す。終了時thermalStateはfair。

captureのpowerでは、同じ端末の事前idle CPU/GPU/ANEが3.977/0.118/0W、後回し全処理区間が6.198/1.681/1.135W、並行が6.105/1.701/1.238W。どちらも保存後の全索引と最後の検索までを含む。process CPU比率は1core相当で67.5% / 81.0%。推論している区間の値であり、idle CPUではない。

この1回では両条件のP90が2秒以内だったが、先行する同じcoordinatorの測定では後回し **2.089秒**、並行 **2.538秒**を観測した（raw JSONは後のinstrumented runに上書きされた）。背景負荷/cacheが異なり、今回の値だけで安定した達成を宣言しない。別の既存SPM E2E 30件では後回しP90 1.45秒、legacy triage並行2.53秒。[30件の結果](../e2e/results/20261014-205419-post-merge-release.json)。legacy harnessはactual coordinatorのcapture pauseを通らないため、上表と直接比較しない。初回STT13.23秒も温間結果から独立して残した。


### 実Releaseアプリのidle

[実アプリidle測定](../e2e/results/20261014-214449-app-idle.json)。一時DBと引数ドメインの設定で起動し、個人DB/defaultsを使わず、Whisper+embeddingの準備完了を確認した。準備後60秒待ち、61.36秒でCPU time差は0.00秒（測定分解能0.01秒）。**0.0163%未満相当**の観測で、絶対的な0%とはしない。current physicalは196MB、lifetime peak physical 2,889MB、参考RSS 1,613MB。d1はidleでは未ロードなので、3モデル推論後のメモリとは条件が違う。起動した測定用processだけを終了し、モデルの置き場への書き込みが無いことを確認した。

再現: 事前にbuildしたRelease appの版を確認し、`CC_E2E_STEPS=c CC_E2E_APP_DERIVED=/path/to/DerivedData CC_E2E_SKIP_APP_BUILD=1 CC_MODELS_DIR=/path/to/models scripts/e2e.sh`。skip指定を外せばアプリをbuildする。新しいskip指定はコンパイルとidle測定を分離するためのもの。実録音・キャプチャは行わない。

## 残る確認と採用条件

- #8 の M3 構成比較・Release・電力測定は完了。長文/透明画像/実データによる品質・互換性は、将来のruntime切替候補を具体化したときに検証する。モデル/pipelineを変える場合は #9 のshadow generationで再索引する。
- #10 のfixture E2Eと3モデル常駐・MainActor待ち・SoC電力を追加した。実キー/マイク/画面/保存toastと、battery/low-power切替時の製品通知・優先度は未検証。policy注入・新着優先・backfill遅延のPoCテストは通過済みだが実状態の測定とは区別する。
- helper製品化は、上記のM1実機試験、合計physical/powerの改善、キャンセル/全step再開/署名配布を確認してから別PRで扱う。既存PoCが利益を示さなかったため、今回の測定追加で製品をhelperへ切り替えない。

検証: 通常のReleaseアプリテスト73件成功（実モデルopt-in 1件skip）、実モデルcaptureテスト1件成功、runtime 3構成成功、power parser 6件成功。shell構文・Python構文・diff whitespaceも確認した。
