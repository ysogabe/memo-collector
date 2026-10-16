# 開発版と通常利用版のデータ分離

この変更後にビルドしたアプリから、次の区分を適用する。インストール場所による推測ではなく、
ビルド構成でアプリIDを決め、そのIDから保存先を選ぶ。

| | 開発版 | DMGからの通常利用版 |
|---|---|---|
| 構成 | Debug / DevelopmentRelease | Release |
| 表示名 | Context Capture Dev | Context Capture |
| Bundle ID / 設定ドメイン | dev.ysogabe.ContextCapture.development | dev.ysogabe.ContextCapture |
| データルート | ~/Library/Application Support/ContextCapture-Development/ | ~/Library/Application Support/ContextCapture/ |
| DB | 上記の ContextCapture.sqlite | 同左 |
| 画像・音声 | 上記の captures/ | 同左 |
| モデル | 上記の Models/ | 同左 |

UserDefaults の設定キーは同じでも、アプリIDが違うので除外アプリ・ホットキー・保存期間・辞書・初回設定は共有しない。
開発版のメニューバーには Dev を表示する。OSの権限も別アプリとして設定する。

## 開発で使う構成

`(cd app && xcodegen generate)` 後、通常は ContextCapture スキームで Run（Debug）。
Release 最適化の速度や動作を確認するときは **ContextCaptureDevelopment** スキームを使う
（DevelopmentRelease。最適化は Release と同じ、保存先・アプリIDは開発用）。

**Release 構成そのものは配布用**であり、ソースからビルドしても通常利用データへ接続する。
DMG作成スクリプトは常にReleaseを使う。新しい開発版と通常利用版を同時起動すると、
同じホットキーが競合するので、一方を終了してから動作確認する。

## 既存データ

自動コピー・移動・削除はしない。これまでの標準保存先の記録・モデル・設定は、そのまま通常利用側に残る。
開発時に作った記録と実際の記録が既に混在している場合も、勝手に分類・削除しない。
必要ならバックアップ後に利用者が整理する。

新しい開発版は空のDB・初期設定から始め、モデルも別途準備する。モデルを完全に分けるため、
追加の保存容量が必要（準備後約5.3GB、取得・変換時は一時的に約13GBの空き）。
旧ビルド済みの開発アプリにはこの分離がないため、それを起動して検証しない。
既存の緑アイコン入りDMGは既に通常利用側の保存先を使っており、利用継続のための移行・再インストールは不要。

## CLI・MCP・テスト用の明示指定

SwiftPMのDebug/Release CLIにはアプリのBundle IDがないため、引き続き既定は通常利用側。
**開発用のCLI/MCPにはデータとモデルの両方を明示する。** 例えば:

```sh
CC_DATA_DIR="$HOME/Library/Application Support/ContextCapture-Development" \
CC_MODELS_DIR="$HOME/Library/Application Support/ContextCapture-Development/Models" \
Packages/ContextCaptureKit/.build/debug/cc-mcp
```

MCPクライアントから起動する場合は、この2変数をそのクライアントのサーバー設定に入れる。
`cc-models` の実行にも同様に適用できる。

`CC_DATA_DIR` と `CC_MODELS_DIR` はアプリでも明示指定として優先する。
`CC_DATA_DIR` だけを変えても、モデルの既定位置はビルド構成に対応したModelsのまま。
環境変数で本番パスを指定すれば分離を意図的に上書きできるので、開発時に本番パスを設定しない。
`--fake` は従来どおり別のフェイク用設定とメモリ／一時ストアを使う。

## 確認

CCPathsTests 12件（うち分離の回帰テスト4件）を実行。
小さなアプリバンドルから共通ライブラリを呼び、実際のBundle IDにより開発／通常のパスが切り替わることも確認。
本物の個人DB・キャプチャ・設定には読み書きしていない。

XcodeGenで生成したプロジェクトと `xcodebuild -showBuildSettings` でも3構成のBundle ID・表示名を確認。
Debugは `-Onone`、DevelopmentReleaseとReleaseは `-O`。変更後のDebugアプリのビルドとアプリ単体テストも成功。生成されたInfo.plistで開発用のアプリID・表示名を確認した。個人データを使ったアプリ起動は行っていない。
