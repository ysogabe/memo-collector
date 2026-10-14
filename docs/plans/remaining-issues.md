# 残件 #1 / #2 / #3 / #5 / #10 の対応計画

2026-10-14。開始時のmainは43bd506、作業は専用worktreeのcodex/remaining-issues。M3 24GiBを対象にする。M4 32GBの利用は前提にしない。

## 実施順と成果物

| 順 | Issue | 作業・検証 | 完了判断 |
|---|---|---|---|
| 1 | #3 | Embeddingの未検証compiledモデル採用を廃止し、固定sourceからのcompileをmanifestで追跡。d1はcheckpoint以外のconfig/tokenizer/licenseも固定hashで検証。準備中表示、pause自動再開ログ、開発fixture投入経路を整える | 改変/欠落/旧manifest/失敗時の既存モデル保持と、実モデルsource検証。開発用read-onlyモデルへは書かない |
| 2 | #5 | #9で解決済みのCASとページングを確認。録音デバイス中断を保存・通知へ伝達、ScreenshotEncoder共有、E2E性能gate、HotKey/ModelSlots/Coordinator/SearchIndexの分岐・競合テストを追加 | 対象テストとcheck.sh。性能は明示opt-inで判定し、不達を成功にしない。OCRのOS差を区別する手順を残す |
| 3 | #2 | read-only DBから手動正解ラベルを取り、保存済み確率または候補criteriaのd1再推論でcoverage/accuracyを比較するCLIを作る | ツールのモデルなし契約と実d1検証。採用/再処理には30〜50件の正解と検証setが必要。手動ラベル0件の状態で閾値を変えない |
| 4 | #10 | 複数passのactual coordinator測定、性能不達時のSTT内訳を確認。実機hotkey/mic/screen/toastと電源状態の受け入れ記録を統合 | fixtureと実機を区別し、未実施を残す。helper製品化は測定利益がない限り保留 |
| 5 | #1 | 上記成果とMVPのWave/PRD受け入れを突き合わせ、実装済み・自動検証済み・利用による確認待ちを整理 | check.sh成功に加え、ユーザー実機と継続利用の受け入れ記録が揃うこと |

## データとリスク

既定DBはmode=roで件数だけ確認し、15件・手動正解ラベル0件だった。個人の注釈本文や媒体はGit・CI・調査ログへ載せない。意図の採用案を作るための正解はユーザーの手動ラベルで、モデルの推定を正解へ転用しない。モデル取得元は固定revisionから検証し、既存のモデル/DBへはテストで書き込まない。

新しい不具合修正には障害・競合・回復を再現するテストを付ける。低影響の文言だけに実装を写したテストを増やさない。PRは成果単位に分け、CI確認後に既存のマージ指示に沿って統合する。完了したworktreeは片付け、primary checkoutをcleanなmainへ戻す。

## 今回の到達点

#3はPR #20、#5はPR #21でマージ・closed。#2はPR #22で評価ツールと手動ラベル時の確率保持を実装したが、採用には手動正解が必要。#10は3pass/60件すべて保存・索引でき、3回目の並行保存P90 2.34秒が性能gate不達だった。#1も最新実機受け入れと性能の安定性を残す。[証拠・判定](../research/remaining-issue-validation.md) と [次の受け入れ手順](../manual-tests/remaining-acceptance.md) にまとめた。
