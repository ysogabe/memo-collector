# 残る実機受け入れ（#1 / #2 / #10）

対象はM3 24GiB。M4 32GBは不要。自動fixtureを実hotkey/mic/screen/toastの結果へ読み替えない。以下は未実施のチェック表で、ユーザーの確認結果を記入する。既存の2026-10-11の本線確認は [MVP計画](../plans/mvp-implementation.md) に残っている。

## #2 の正解を集める

普段のInboxで意図を手動修正し、30〜50件を目指す。今回の修正で手動ラベルと元の推論確率を両方残す。別の手動正解JSONでもよい。[評価手順](../../evals/intent/README.md) を実行し、developmentで案を選んでholdoutで検証する。現行0.7・製品質問文・既存記録は評価後に変更する。

## #1 の本線と #10 の性能

[起動・権限の手順](m1.md) と [M2/M3の手順](m2-m3.md) を使う。モデルルートは `spikes/dev-models`（whisperkit、d1-3b-text-q8、embeddinggemma-2-coremlが揃う場所）。既に起動中のアプリはユーザーが終了してから、同一署名のReleaseアプリを `open` で起動する。試験DBは `CC_DATA_DIR` で個人DBから分ける。

| 試験 | 期待結果 | 結果 |
|---|---|---|
| warm-up完了後、実マイクで1〜3秒のメモ20件以上 | 押下→録音開始 ≤150ms、解放→保存toast P90 ≤2秒。件数と冷間/温間を記入 | 未実施 |
| triage中に次の実キーを押し、連続10組以上 | 新しいstepがcapture中に始まらず、全件保存。W7-5のP90とnoticeを記録 | 未実施 |
| 1件が遅いときの sttBreakdown | wait / enc / dec / fallback を記録。注釈本文や画面は調査ログへ載せない | 未実施 |
| 録音中のデバイス中断・画面権限拒否との同時発生 | 音声があれば保存し中断を通知。両方の注意を表示 | 未実施 |
| 再試行中の取り消し | 記録/添付が消え、再試行完了でも復活しない | 未実施 |
| needs_review画像のMCP要求、マスク後の再要求 | 未確認の生画像を返さず、マスク画像だけ返る | 未実施 |
| Claude Codeから list_inbox / get_record / search_records | 実クライアントとのstdio・検索key整合を確認（MCP単体テストとは別） | 未実施 |

権限の変更や電源モードの変更はユーザーが行い、終わったら元の状態へ戻す。実音声・画面・DBをGitへ入れない。プロファイルを採る場合は数値の集計だけを残す。

## #10 の電源状態と製品接続

現在のlow-power/battery/high-load policyはworker PoCで注入して検証したもので、アプリのOS電源通知へは接続していない。したがって「切替時に製品の優先度が変わった」とはまだ検証できない。helper / policyを製品へ採用するかを先に判断し、採用時はOS通知→policy→新着優先/backfill遅延を小さい別PRで接続してから次を測る。

| 状態 | 記録するもの | 結果 |
|---|---|---|
| AC / 通常 | warm capture・待機CPU・physical・SoC電力の基準 | fixtureとidle基準は実測済み、実captureは未実施 |
| batteryへ切替、ACへ復帰 | OS通知時刻・製品policy変化・新着保存・backfill再開・取りこぼし | 製品接続の採否待ち |
| 低電力をON/OFF | 同上。変更はユーザー実施 | 製品接続の採否待ち |
| 同じ負荷を加えた高負荷条件 | 負荷内容・thermalState・P90・STT内訳・保存/索引件数 | 制御した実機試験は未実施 |

helperを置くだけではANEの共有資源や熱制約は隔離できない。連続passの3回目にencoderが伸びた結果を踏まえ、次の性能実験は同じ入力・OS・電源状態で、STTのcompute構成とbackground推論の開始間隔を別々に比較する。高負荷・熱状態の原因を断定せず、品質(CER)と保存遅延の両方が改善した候補だけを採用する。
