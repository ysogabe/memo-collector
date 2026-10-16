# DMG リリースの作成

Context Capture は、アプリを Applications にドラッグしてインストールする DMG を作成できる。
DMG はサイト等で直接配布するための形式。Mac App Store への提出パッケージではない。
現時点の申請・公開前の残作業は [配布監査](release-audit-20261016.md) を参照する。

## 手元確認用

Xcode、XcodeGen、Python 3.9 以降、Metal Toolchain、依存を取得できるインターネット接続が必要。

```sh
python3 scripts/release.py --preview
```

`dist/ContextCapture-<version>-<build>-arm64-PREVIEW.dmg` と SHA-256 を生成する。
これは ad-hoc 署名・未公証の開発者確認用であり、一般向け配布版として公開しない。
既存の開発版と署名が異なるため、置き換えた場合は権限の再許可が必要になることがある。
別 Mac の Gatekeeper 通過は保証しない。システムのセキュリティ設定を無効化する必要はない。

## Developer ID 署名・公証付き

Apple Developer Program の Developer ID Application 証明書と秘密鍵をキーチェーンに用意する。
既存の `notarytool` キーチェーンプロファイルを利用する。資格情報をリポジトリやコマンドファイルに書かない。

```sh
python3 scripts/release.py \
  --identity 'Developer ID Application: <name> (<TEAMID>)' \
  --notary-profile '<keychain-profile>'
```

証明書とプロファイルは `CC_RELEASE_IDENTITY` / `CC_NOTARY_PROFILE` でも指定できる。
`app/project.yml` の Team は証明書の Team と合わせる。バージョンは同ファイルの
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` を更新する。同名の既存 DMG は上書きしない。
`--output <directory>` で出力先を変更できる。

スクリプトは以下を実行する。

1. リポジトリの `Package.resolved` に依存を固定し、独立した一時 DerivedData で Release / arm64 / Hardened Runtime ビルド。
2. ビルドされた `.app` のみコピー。バンドル ID、実行ファイル、署名、外部を指すリンクを検査。
   DB、録音、HEIC、モデル重み、モデルディレクトリ、秘密鍵などの既知の混入を拒否する。
   これは全種類の個人情報を検知する仕組みではない。ソースの Resources に追加する素材もレビューする。
3. 配布モードではアプリを公証し、ticket を staple、Gatekeeper で評価。
4. `.app`、`Applications -> /Applications`、案内テキストを UDZO DMG に格納。
5. 配布モードでは DMG も署名・公証・staple・Gatekeeper 評価。
6. DMG の検証と読み取り専用マウントを行い、内部のアプリとリンクを再検査。
7. 検査に通った DMG と SHA-256 を出力。一時ビルド・マウントは終了時に片付ける。

署名は Xcode に任せる。`codesign --deep` による一括再署名は行わない
（`--deep` は内包コードの検証にのみ使用）。エラー時は非ゼロで停止し、配布物として出力しない。
公証は Apple のサービスにアプリを提出する。`--preview` は提出しない。

## 開発版との分離

Debug / DevelopmentRelease は開発用の別アプリID・データ領域を使う。
既存データはRelease（通常利用）側に残す。[保存先と開発手順](development-data.md) を参照。

## 利用者のインストール・更新

DMG を開き、`Context Capture.app` を Applications にドラッグする。
旧版が起動中なら終了してから置き換える。DMG を取り出して Applications のアプリを起動する。
初回は権限設定とモデル準備が必要。アプリの置き換えは個人の DB・キャプチャ・モデルを変更しない。
DMG 内から起動しても書き込みはアプリ外のユーザーデータ領域に行われるが、通常はコピー後に起動する。
自動インストーラや管理者権限を使ってユーザーデータを作成しない。

`.app` をゴミ箱に移してもデータは残る。完全削除はアプリ・MCP を終了して、必要なバックアップを取り、
`~/Library/Application Support/ContextCapture` と当該アプリの設定を削除する。
モデル削除と個人記録の削除は別の操作。モデルだけを消しても DB・キャプチャを削除しない。

## 配布前の実機確認

- `scripts/check.sh` を実行。署名・公証後の DMG は別ユーザー／クリーンな Mac でも確認する。
- HTTPS から実際にダウンロードした quarantine 付き DMG で、警告なくインストール・起動できること。
- マイク・画面収録・Accessibility・ブラウザAutomationの許可／拒否、モデル取得の中断・再開、オフライン動作。
- 旧版で作成したテスト記録が更新後も読めること。権限は署名方式の移行で再許可が必要になり得る。
- DMG の取り出し、アプリ終了、モデル取得中の終了、低容量時の動作を確認。
- プライバシー、アイコン、ライセンス等は監査文書の残項目を完了する。

パッケージ検査の単体テストは `python3 -m unittest discover -s scripts/tests -p test_release.py -v`。
アプリの実ビルド・マウント検査は `--preview` の実行に含まれる。

`cc-mcp` は今回の DMG に含まれない。現状の README のソースビルド手順が必要。
一般利用者向けの MCP バイナリ同梱・署名と接続手順は別途対応する。
