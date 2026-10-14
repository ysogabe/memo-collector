# ADR-0002: 入力バージョンと DB 内の索引世代

状態: 提案（実装とテストを伴う）。関連 #9 / #5。基準: ADR-0001。

## 決定

検索空間の互換性をモデルID・固定revision・runtimeのベクトル版・量子化・次元・画像予算・前処理版・vector schema版から作る。CPU/GPU/ANEは既存のparity検証を続ける同一互換群とする。前処理/ベクトルの意味が変わったら対応する版を更新する。

DB v2で `record_input_versions`, `index_generations`, `generation_embeddings`, `generation_jobs`, `index_generation_pointer` を追加する。元の `records` と `embeddings` は削除しない。新世代はshadowとして作り、最新入力がすべて揃ったことを確認した同じ書き込みトランザクションでactiveポインタを切り替える。旧ベクトルと新ベクトルを同じ検索行列に混ぜない。

## 書き込みと編集

入力版は注釈・タイトル・元画像のパスの変更で増える。レコード・入力版・write targetは一つの読み取りトランザクションで読み、画像の読み込みより前に確定する。結果はその入力版と実際に推論したモデルの互換性鍵を同じトランザクション内で照合して保存する。モデル切替中に走っていた推論も、捕捉したモデルの鍵を返す。

入力hashは版・注釈・タイトル・画像パスを含む。保存済みの元画像は不変の入力として扱い、参照済みパスへの `writeAttachment(.screenshot)` 上書きを拒否する。参照確認と原子的ファイル書き込みはDB writerと直列化する。画像を変更するなら新しいパスを保存してレコードを更新する。管理API外で画像ファイルを直接書き換える操作は入力整合性の保証対象外。

世代を開始したストアでは、互換性を伝えない旧 `setEmbedding` は拒否し、`commitEmbedding` を使う。メモリ上だけのフェイク等、世代を持たないストアの契約は維持する。

## 再構築と復旧

pending index jobと結果の入力版をDBに残し、再起動後は不足分のIDをページ単位で取得して再開する。新着・編集はactive/building世代のjobを同じDBトランザクションで更新し、削除はFK cascadeで処理する。現行TriageQueueの逐次処理・重複統合・一回の再試行を使う。

部分失敗ではactiveポインタを切り替えず、appは失敗を表示して文字一致へfallbackする。旧世代とそのencoderが対応できるcc-mcpは旧索引を継続する。入力版が変わった古いベクトルはどの世代でも検索から外す。新世代への再試行は同じcompatibility keyのshadowを再利用する。

切替直前の新着/編集も完了条件に含む。古いactivate要求は各await境界で取り消しを確認し、最新のモデル/targetを上書きしない。rollback APIは旧世代が現在の全入力に対応するときだけポインタを戻す。変更後の旧世代が未更新なら、旧モデル設定で不足分を再構築してから切り替える。

## 検索と状態

queryは実際に推論したencoderの鍵を返し、DBのactive世代と同じ読み取りトランザクションで照合して検索する。cacheはactiveポインタ・世代ベクトル・入力版の変更で無効化する。異なる鍵なら検索を拒否してkeywordへfallbackする。

`search-index.json`は互換/診断用の出力。世代対応cc-mcpはDBのactive metadataを正本とする。JSONの書き込み失敗やポインタ切替との競合で異なる空間を比較しない。新旧のapp/cc-mcpを混在させず、両方を更新する。索引rollbackと旧バイナリへのDB downgradeは別の操作である。

## 移行と保持

v1→v2の前にSQLite backup APIでWALを含む整合したsnapshotを作り、完了した単独ファイルを `ContextCapture.sqlite.pre-index-v2-backup` として公開する。読み取り専用でquick_checkとrecords表を検証してから移行する。未完了のpartialファイルを完成バックアップとして使わない。既存の完成バックアップは上書きしない。

旧JSONのシグネチャだけでは前処理版を証明できないため、旧ベクトルを新しい世代として推測で採用しない。初回は文字一致へfallbackしてshadowを作る。元記録・旧ベクトル・移行前snapshotを保持する。旧世代/backupの自動削除は今回含めない。

## 検証範囲

SQLite実体でv1移行と元BLOB保持、再オープンでshadow再利用、古い入力/異なる鍵の拒否、新着/削除/編集との整合、別接続のcache、原子的切替、旧世代rollback、元画像上書き拒否を確認する。appの結合テストはモデルをフェイクにして、失敗時の旧世代保持・不足分再開・取り消し競合・検索fallbackを確認する。必須の `scripts/check.sh` は実モデル指定で実行する。

#5のembedding check-then-actはこの条件付き保存で解消する。起動時のresumePending全件JSON走査は既存のguard/intent再開に残る。今回ページ化するのはshadowの再構築。一般のguard/intent/STTジョブ、lease/backoff/helper分離は#10で扱う。モデル供給網の検証強化は#3のまま。
