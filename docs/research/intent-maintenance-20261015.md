# 意図の保守CLI検証（2026-10-15、#2）

60%基準はPR #27で採用済み。今回のCLIは既存の自動意図を同じ製品の質問文で再推論するための保守経路であり、新しい質問文や分類精度の採用判定ではない。

## 実装と保全

`cc-models reprocess-intents` は既定でreadonly集計。`--apply --backup <新規SQLite>` の組合せを明示した場合だけ、準備済みd1のmanifest/sha256検証・モデルload・整合バックアップの順に進む。モデル取得や変換は行わない。実行時は通常アプリを終了して録音とのモデル競合を避ける。

製品TriageQueueのintent stepだけを使い、手動意図、開発fixture、未処理、前処理後の空注釈は除外する。書込時も最新行をtransaction内で確認し、manual/注釈競合を保護する。DB migrationや添付アクセスは行わず、更新はtriageとその検索列だけ。索引、世代、入力version、未知JSONフィールドは維持する。バックアップ/集計はデータ・モデル領域外の新規ファイルに0600で作り、既存ファイルを上書きしない。レポートは件数のみで、本文・ID・URL・添付パスを含めない。

## 親による検証

- package関連60テスト成功（CCCore11、CCStore8、CCTriage41）。
- CLIの独立process契約21テスト成功（評価10、再処理11）。readonly、上書き/リンク/破損DB保護、モデル未準備時の非取得・非書込を含む。
- M3 24GiBでmanifest付きローカルd1を用いた合成4件のapply成功。自動1件だけnoteからcodeへ変化し、manual/空/未処理の3件は不変。backup integrity=ok、0600、schema/user_version、索引sentinel、未知JSONとtriage以外の全項目の不変を確認した。
- manifestの無い開発モデルはモデルload/backup/書込より前に拒否した。正式な配置へ切り替えて検証を完了した。
- 独立手動のセキュリティ/境界レビューで信頼度7以上の指摘なし。専用security-review skillはこの環境に存在せず、同skillを実行したとはしない。

## 通常データのreadonly確認

開始時は15件、手動正解0件。保存済み自動ラベルは未分類11、code1、research2、note1。保存確率は全件有効で、70%で4件、60%で6件が分類可能となる件数比較だった。これは正解率でも再推論結果でもない。元の質問文/モデル来歴が不明な保存確率を混ぜた精度の主張はしない。

`eval-intent` は `needs_manual_labels`、終了code2を返した。ユーザーにInboxでの手動確認を依頼済みで、回答待ち。個人DBは今回のCLIで書き換えていない。全15件を確認しても30〜50件の目安に不足するため、探索的集計に留める。多様な正解データの収集と候補決定前のholdout確保が終わるまで、新しい質問文・既定分類の採用やIssue #2の完了は宣言しない。

個人の本文・画像・音声・URL・ID・DB・実行生ログはリポジトリへ含めない。実データのバックアップ/集計はMacのprivate領域に保持する。

## 個人DBのprivateコピーでの追加確認

通常DBを読み取り専用で開き、privateな整合コピーを作った。本文等を外部送信せず、同じローカルd1で15件すべてを再推論し、失敗0、分類変更2件。コピー上の分類は未分類9、code1、note2、research3となった。全他テーブル・schemaと各recordのtriage以外のJSONが不変であることを比較した。正解ラベルなしのためcoverage/accuracyの改善とはしない。通常アプリが使うDBは変更していない。

検証準備ではHomebrew Python SQLite 3.53.3のbackup出力をWALのまま閉じると、system SQLite 3.54.0の初回readonly quick_checkがrc14で失敗した（3/3）。Python側の読取後には成功し、別processでsystem SQLite自身が作成/終了した合成WAL DBでは初回から成功したため、通常アプリ終了後の一般的な失敗へ拡張しない。正確な内部原因は未特定。バックアップ先をDELETEへ明示正規化して閉じると、事前読取なしで3/3成功した。製品CLIのbackupは既に同じ正規化を行っている。immutable、WAL無視、読取失敗時の自動書込への切替は行っていない。通常DBとコピーの取り違えを避け、準備時の失敗も記録として保持する。
