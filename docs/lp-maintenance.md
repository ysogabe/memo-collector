# LP の更新手順

公開先: https://ysogabe.github.io/memo-collector/ 。`main` の `lp/**` を変更すると、[Pages workflow](../.github/workflows/pages.yml) が `lp/` だけを公開する。Issue・PR の確認とマージ後、Actions の deployment 成功と公開 HTML / 画像の一致を確認する。

## アプリ画像

2026-10-15 は Release 0.1.0（source `00e95ef315c530105156cebba5933eaa5f0f711b`、PR #24 merge `2bc6ff0`）を使用。画像のハッシュと出典は [screenshots.json](../lp/assets/screenshots.json) に記録した。

アプリに組み込まれた `SnapshotRenderer` を実行する。HTML で UI を再現するのではなく、実際の SwiftUI / AppKit の View を NSWindow 上で描き、そのピクセルを PNG に書き出す。アプリの外枠は含まない。`--fake` はデータと外部依存をサンプルにするためで、個人 DB、マイク、個人の画面は使わない。検索結果もサンプルモードの表示であり、実モデル精度の証拠にはしない。添付として見せるページ画像・トークンは合成データで、そのことを LP に明記する。

```zsh
# scripts/check.sh などで現在のソースからビルドした後に実行
DerivedData/Build/Products/Debug/ContextCapture.app/Contents/MacOS/ContextCapture \
  --fake --render-snapshots /tmp/context-capture-ui
```

`inbox.png`、`detail.png`、`inbox-search.png`、`detail-needs-review.png`、`settings.png` を `lp/assets/app-<元の名前>.png` にコピーする。出力した画像は加工せず、そのまま掲載する。透明な画素を持つ画面があるため、Web 側の `.app-screen` に白背景を指定している。各画像の原寸、読みやすさ、サンプル以外の情報が入っていないことを目視で確認する。ハッシュ・ソース commit・撮影日を出典に更新する。

## 説明と検証

- 製品に接続された機能はアプリソースで確認する。PoC のハイブリッド検索、helper 分離、OS の省電力連動などを実装済み機能として書かない。
- 速度は温間 / 初回、合成音声 / 実マイク、保存完了 / 通知描画を分ける。検索は画像あり / テキストのみと評価用データの範囲を添える。実測レポートは GitHub の絶対 URL へリンクする（`docs/` は Pages に含まれない）。
- メール受付のバックエンドがないため、受付成功を装うフォームは置かない。ソースと Releases に案内する。
- 外部エージェントの送信先、MCP の画像ガードとテキストの別扱い、未完了の実機確認を説明と整合させる。

```zsh
python3 -m http.server 8791 --bind 127.0.0.1 --directory lp
```

デスクトップと幅 390px 程度のモバイルで表示を確認する。画像の原寸リンク、ページ内ナビ、FAQ、資料リンクが機能し、横にはみ出さないことを確認して PR を作る。マージ後の Pages workflow が成功したら、公開先の HTML と画像が新しい commit の内容と一致することを確認する。
