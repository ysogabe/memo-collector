# 残件対応とM3の受け入れ状況（2026-10-14）

[対応計画](../plans/remaining-issues.md) に沿い、#3のモデル供給網・準備経路をPR #20、#5の競合/中断/QAをPR #21としてマージした。#2の評価CLIと手動修正時の確率保持はPR #22。測定はM3 24GiBを使い、M4 32GBは前提にしていない。

## 判定

- #3/#5: 修正・テスト・CIを完了してclosed。
- #2: 評価ツールは実装・検証済み。既定DBは15件・手動正解0件なので、質問文/しきい値の採用と再処理は未実施。30〜50件の正解を集めてから判断する。
- #10: 3pass計60件の保存/最新世代索引/query整合は成功。3回目の並行triage保存P90は2.34秒で性能gate不達。実hotkey/mic/screen/toast、電源状態の製品policy接続・実機検証を残しopen。
- #1: 実装は揃い、check.shとWaveの自動検証は成功している。2026-10-11のユーザー本線確認も既存計画に記録済み。一方、最新修正後の実機受け入れと安定した保存P90≤2秒を満たしたとは言えないためopen。PRDの4週間の成功指標は運用評価で、実装完了条件とは区別する。

## Release captureを3pass

ソースは469e4ae（PR #22の評価機能を含む、手動確率保持の修正前）。実行バイナリは事前buildしたReleaseのhostless XCTest。fixture hardware、実AppCoordinator/TriageWiring/Whisper/d1/CoreML/Vision/SQLite。起動・初回STTと温間captureを分離し、各processで10件ずつ後回し/並行triageを再生した。3passを連続して実行し、cache消去や電源設定の変更はしていない。他のCodex build/testは測定中に走らせていない。背景アプリの負荷は完全制御していない。

| pass | 後回し P90 ms | 並行 P90 ms | 並行capture physical peak MB | 保存/索引 | 終了thermalState | gate |
|---|---:|---:|---:|---:|---|---|
| 1 | 1480.1 | 1608.0 | 3922.2 | 20/20 | nominal | 合格 |
| 2 | 1590.0 | 1762.5 | 3935.4 | 20/20 | fair | 合格 |
| 3 | 1744.6 | 2339.5 | 3791.1 | 20/20 | fair | 不達（並行P90） |

保存・音声/画像の添付path・latest generationの未索引0・全件のquery key一致を各passの実テストでassertした。最大でも10GBのactive physical条件を満たし、d1解放後の4GB条件も満たした。実録音開始≤150msや保存toastの描画速度はfixtureでは測れない。3回のうち良いpassだけを採用せず、gate不達をそのまま保持する。

結果: [pass1 capture](../e2e/results/20261014-m3-followup-pass-1-capture.json) / [gate](../e2e/results/20261014-m3-followup-pass-1-gate.json)、[pass2 capture](../e2e/results/20261014-m3-followup-pass-2-capture.json) / [gate](../e2e/results/20261014-m3-followup-pass-2-gate.json)、[pass3 capture](../e2e/results/20261014-m3-followup-pass-3-capture.json) / [gate](../e2e/results/20261014-m3-followup-pass-3-gate.json)。

### 不達のSTT内訳

[60件の数値とraw log SHA256](../e2e/results/20261014-m3-followup-stt-diagnostics.json)。ログのmsは丸め値で、上表の正確な保存時間とは区別する。waitは全件0ms、fallbackは全件0。並行triageのencoderはpass1の1101〜1294ms、pass2の1302〜1486ms、pass3の1494〜1979msへ伸びた。pass3の最大保存2441msではSTT2433ms、encoder1979ms、decoder444msだった。

保存処理そのものやモデル読み込み待ちが主因ではなく、STT推論の増加が観測された。thermalStateと経過passが同時に変わるので、熱・ANEの混雑・背景負荷のどれが原因かはこの記録だけでは確定できない。helper processを増やしても共有ANEや熱制約の改善は保証されない。既存helper PoCは総メモリの改善も示していないため、製品への導入は保留する。

次の性能実験は同じ入力・モデル・電源条件を固定し、STTのcompute構成とbackground推論の開始間隔を別々に比較する。負荷/thermalを記録し、CERとレイテンシの両方から採用を判断する。STT前の暫定保存を「保存成功」へ数え替える変更は、クラッシュ復旧・noSpeech・UIの別設計として扱う。

## MVP/Waveの証拠と残る項目

| 範囲 | 自動検証・実装済みの証拠 | 残る受け入れ |
|---|---|---|
| Wave0/1 store・capture | CRUD、CAS、世代、missing IDsのpaging、添付失敗、録音中断、HotKey driverの失敗/再設定 | 実権限・キー・マイク・スクショの最新修正後の確認 |
| Wave1 STT・intent | 既存CER/参照確率/トークン一致、今回の実d1候補一致、手動正解を上書きしないqueue | 実メモの正解収集、STT encoderが遅い条件の比較 |
| Wave2 UI/wiring | 全Appテスト91件成功、実coordinator fixture60件。過去のユーザー本線確認あり | 実HUD/toast・録音開始、取り消し/再試行、ブラウザURL/ウインドウ |
| Wave3 embedding/guard/triage | 検索回帰CI、14 OCR fixture、マスク、強いpause、pending scan/lifecycle | OS差のOCR手順、ユーザーのneeds_review確認とマスク操作 |
| Wave4 MCP | stdio/ガード済み出力/実SQLite検索の結合テスト | 実Claude Codeからの操作の受け入れ |
| Wave4 nonfunctional | M3のRelease runtime/SoC電力/idle、今回の3pass physical | 並行保存P90の安定達成、実状態のbattery/low-power/high-load |

PRD §10のApple M1 / 16GBという元の測定対象について、このM3 / 24GiBの結果を16GB機での実測へ読み替えない。ここでの「M1本線」はmilestone 1の意味。[実機チェック表と製品policyの未接続範囲](../manual-tests/remaining-acceptance.md) を入口にする。

検証: #5で全体check.sh（実モデルを含む）成功。#2の対象check.shと全Appテスト成功（92件中、91件成功・実モデルopt-in 1件skip）、CLI契約9件成功、実d1候補の確率一致3件成功。3passの実モデルcaptureテストは各成功、性能gateは2合格/1不達。後続の署名付きReleaseアプリは再buildし、計測対象との変更点は手動ラベルで確率を保持する修正だけでcapture中には使われない。
