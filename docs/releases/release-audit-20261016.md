# 配布・Mac App Store 申請を想定した監査（2026-10-16）

## 判定と範囲

**DMG 作成の仕組みを追加した。一般公開と Mac App Store 申請は、まだ準備完了ではない。**
保存先の基本設計は直接配布する macOS アプリとして妥当。
開発用Debug / DevelopmentReleaseのデータ・モデル・設定は、[開発用の別領域](development-data.md)へ分離する変更を追加した。
Mac App Store 向けは Sandbox とアプリ間連携の設計見直しが必要。
この確認はソース・設定とパッケージ作成の検証であり、Apple の審査承認を保証するものではない。
App Store Connect への登録・アップロード・公開、公証の実送信は行っていない。

対象: `app/project.yml`、Info.plist / entitlements、CCPaths、CCStore、CCModels、
AppEnvironment / LiveServices、SystemPermissions、Onboarding / Settings / RecordingHUD、
CCCapture のホットキー・ウインドウ・ブラウザ URL・スクリーンショット取得、CCMCP。

## ファイル配置・個人データ

| 対象 | 現在 | 評価・残作業 |
|---|---|---|
| アプリ本体 | Applications に置く `.app` | DMG は本体と Applications リンク、案内のみ。利用者の Library をコピーしない |
| 個人 DB | `~/Library/Application Support/ContextCapture/ContextCapture.sqlite` | アプリ内部の永続データとして妥当。`.app` 更新から独立。WAL/SHM を含む整合したバックアップが必要 |
| キャプチャ | 同ディレクトリの `captures/YYYY/MM/DD/` | 非公開のアプリ管理データとして妥当。Documents/Desktop に自動散布しない。音声・画像・文字起こしは機密性のある情報として扱う |
| モデル | 同ディレクトリの `Models/` | オフライン動作のため保持する追加リソースとして妥当。Caches に置くと OS が消せるため、そのまま移すべきではない。再取得可能なモデルのバックアップ除外を追加検討 |
| モデル取得・変換の途中 | Models 下の `.downloads`、変換用作業領域、HF のキャッシュ参照 | 成功時の掃除はあるが、失敗・中断後の残容量、再開、キャッシュ上限の実機確認が必要。開発用 HF キャッシュ探索と製品向け保存先を整理 |
| 設定 | アプリの `UserDefaults`（`ContextCapture.settings.v1`） | Preferences に任せる設計として妥当。インストーラから直接 plist を作成しない |
| 診断 | Application Support 内 `diagnostics/` | 永続診断として動作するが、長期保存・容量上限と機密情報を確認。使い捨てログは Library/Logs、再生成物は Caches への分離を検討 |
| パス API | home に `Library/Application Support/ContextCapture` を連結 | 直接配布では動作。将来は Foundation の applicationSupportDirectory を使い Sandbox コンテナ対応を明確にする。既存データの無断移動はしない |
| 外部パス指定 | `CC_DATA_DIR` / `CC_MODELS_DIR` | 開発・CLI の指定用。通常の DMG 起動で利用者が設定する必要なし。Sandbox 版では環境変数だけではアクセス権を得られない |
| アンインストール | `.app` 削除後もデータは残る | macOS の一般的な動作。モデルだけの削除／個人データの完全削除・書き出しの UI と案内を今後整備 |

DB・キャプチャは失うと再取得できないため Caches / tmp へ移さず、バックアップ除外もしない。
モデルだけを再取得可能なリソースとして扱う。[Apple のファイルシステム解説](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)

個人データの暗号化、所有者だけのアクセス権、別アカウントからの読み取り、SQLite削除後の残存、
DB移行前バックアップの保持期間は未検証。OS の FileVault とアプリ自身の暗号化は別の保護として説明する。
通常の読み書きは相対パスを使用し、MCP は実体がデータルート内の通常ファイルか確認する実装がある。
今回、実ユーザーの DB・キャプチャ・モデルの内容は読み取っていない。

## 直接配布（DMG）の公開前項目

| 優先度 | 項目 | 現状と必要な対応 |
|---|---|---|
| 必須 | Developer ID・公証 | 現設定は Apple Development 署名。公開版では Developer ID Application + Hardened Runtime + timestamp + notarization + staple に切り替える。スクリプトに経路を追加。今回、証明書・公証プロファイルを使った経路は未実行 |
| 対応済み・実機確認対象 | アプリアイコン | 緑の吹き出し＋キャプチャ枠案を採用し、16〜1024px の AppIcon を登録。ビルド成果物への同梱を検証。Finder の表示は配布前の実機確認対象 |
| 必須 | 第三者ライセンス | SwiftPM の依存とコピー由来コードを含め、固定した実バージョンの LICENSE/NOTICE を集約しアプリ内に同梱・表示する。リポジトリの MIT LICENSE だけでは不十分 |
| 必須 | モデルの利用条件 | d1 は LFM Open License、Embedding は変換元・元モデルを含めた条件、Whisper は配布元を確認。manifest/ライセンス保存の実装はあるが、商用利用条件・改変表示・権利を再確認。Apache と記載したコメントだけで法的確認済みとしない |
| 必須 | プライバシー説明 | 公開ポリシーとアプリ内の容易な入口を用意。音声・画面・URL・文字起こし、ローカル保存、保存期間、削除、モデル取得先との通信、MCP を介した外部提供を説明 |
| 要検証 | 初回取得 | UI は取得ボタンと通信・容量の説明があり、無断で巨大モデルを同梱しない。取得は約8GB、変換後約5.3GB、作業時約13GBという区別を配布案内でも統一 |
| 要検証 | 記録の同意と表示 | Push-to-talk、初回説明、権限要求、録音 HUD がある。許可拒否・HUDが隠れるケース・画面取得のタイミングは実機で確認 |
| 要検証 | 署名移行・更新 | Bundle ID は維持。Apple Development から Developer ID への移行時の TCC 再許可、旧データ、DB移行を確認。古いアプリを終了してから置換する |
| 制限 | MCP の配布 | DMG はアプリのみ。cc-mcp の署名付きバイナリ、製品向け導入UI・認可境界は未提供 |

公証の具体的な流れは [Apple の公証資料](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) に従う。
署名・公証を通過しても、ライセンスやプライバシーの問題が解決したことにはならない。

## Mac App Store を仮定した追加チェック

| 判定 | 項目 | 根拠と対応 |
|---|---|---|
| ブロッカー | App Sandbox | `ENABLE_APP_SANDBOX: NO`、entitlements に app-sandbox がない。ストア版では必須。単に YES にするだけでは現在の機能を維持できない |
| 設計検証が必要 | Accessibility | `FocusedWindowReader` は他アプリの AXUIElement を読み、ホットキーのフォールバックに CGEventTap を使用。Apple は assistive app の Accessibility API 利用を Sandbox 非互換の例に挙げている。前面タイトル・画面特定・入力監視を含む製品仕様をストア版で実証し、必要なら機能を再設計 |
| 設計検証が必要 | ブラウザ Automation | NSAppleScript と一般の automation.apple-events entitlement を使用。Sandbox では相手アプリの scripting access group 等に沿った設計・審査説明が必要。現在の entitlement だけで Sandbox 通過と考えない |
| 設計検証が必要 | MCP と DB 共有 | 外部 cc-mcp が既定の同じ DB を開く構成。Sandbox 版の private container を外部ツールが当然読める前提は成立しない。App Group 対象、ユーザー選択の共有領域・認可、export 等の方式を再設計。直接配布版からのデータ移行も必要 |
| ブロッカー | PrivacyInfo.xcprivacy | 自前のマニフェストがない。UserDefaults、systemUptime、空き容量取得を使用。用途ごとに承認理由を照合し、依存 SDK のマニフェスト・署名も含めて Xcode の Privacy Report を確認する。理由コードを利用実態と無関係に追加しない |
| ブロッカー | プライバシーポリシー | App Store Connect とアプリ内のリンクが必要。README のローカル処理の説明だけでは代替できない |
| 要審査説明 | モデル追加取得 | 初回モデル取得はユーザー操作、アプリ内で変換・最適化。追加の実行コードは取得しないことを確認し、審査時点で全機能・ダウンロード先を利用可能にして説明する。重みファイルだから必ず承認されるとは断定しない |
| 要検証 | 自己完結性 | インストール後に Python/Homebrew/ターミナルでのモデル準備を要求しないことをクリーン環境で確認。現モデル変換は Swift の実装。MCP は任意機能としてアプリ単独の基本機能と分ける |
| 未完了 | 提出物 | Store用署名・プロファイル、Xcode archive、App Store Connect、正式アイコン、実際の仕様に合うスクリーンショット、サポートURL、年齢レーティング、価格・配信地域、審査メモを準備 |
| 未検証 | 品質・利用環境 | 対応macOSでのクリーンインストール、低容量、IPv6-only、オフライン、モデル取得失敗、VoiceOver・キーボード操作・リソース消費を確認 |

Sandbox の要件と非互換機能については [Apple の Sandbox 解説](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、
マニフェストは [Required Reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) を参照する。
ストア固有のパッケージ・モデル追加取得・録音表示・プライバシーは
[App Review Guidelines（2.4.5 / 2.5.2 / 2.5.14 / 5.1.1）](https://developer.apple.com/app-store/review/guidelines/) を照合した。

## 推奨する順序

アイコンは設定済み。次に直接配布用DMGのライセンス・プライバシー説明を整え、Developer ID証明書で公証し、
クリーンなMacで受入確認する。次にストア版の Sandbox で AX/Automation/MCP が成立するか小さく実証する。
ストア版は配布設定を分離し、既存の直接配布版とデータ互換・移行を設計してから申請する。

## 今回の検証結果

- `python3 -m unittest discover -s scripts/tests -p test_release.py -v`: 6件成功。
  DB本体・WAL/SHM・移行バックアップ、モデル、秘密鍵、外部リンクの拒否、内包リンクの許可、公証結果が Accepted でない場合の停止を確認。
- `python3 scripts/release.py --preview`: Release / arm64 ビルド成功。
  アプリの署名検証、DMG生成・チェックサム検証・読み取り専用マウント後の再検査と取り出しまで成功。
- 出力: `dist/ContextCapture-0.1.0-1-arm64-PREVIEW.dmg`、SHA-256照合成功。
- キーチェーンへのアクセスを許可した確認では Apple Development ID はあるが、Developer ID Application ID はない。
  本番署名、公証サービスへの送信、staple、公開DMGのGatekeeper評価は未実施。
- 実ユーザーのデータを使ったアプリ起動、Applicationsへのインストール、TCC設定変更、App Store申請は行っていない。
  クリーン環境での利用者向け動作確認は配布前に必要。
- 初回のsandbox内ビルドはXcodeキャッシュ等へのアクセス制限で失敗。許可された環境で上記の実ビルドを完了した。
  Xcode 27では `hdiutil attach/detach` に非推奨の警告が出るが、今回の検査・取り出しは成功した。

### 緑アイコン適用後の確認

- `AppIcon.appiconset` に16〜1024pxの全10枠を登録し、各画像の寸法を確認。
- `python3 scripts/release.py --preview --output dist/green-icon` が成功。
- 新DMGを読み取り専用でマウントし、Info.plist の `CFBundleIconFile` が指す `AppIcon.icns` を確認。
- 新出力: `dist/green-icon/ContextCapture-0.1.0-1-arm64-PREVIEW.dmg`。SHA-256照合成功。
  以前のアイコンなしDMGは `dist/archive/iconless/` に移動。
  当初の `dist/ContextCapture-0.1.0-1-arm64-PREVIEW.dmg` も緑アイコン入りに更新し、取り違えを防いだ。

- 旧DMGが開かれていたため、更新後のDMGをマウントして確認。macOSの `NSWorkspace.icon(forFile:)` が返す画像も緑アイコンであることを確認。
