# 実機確認手順: CCCapture（Wave 1 capture）

`swift test` では権限（画面収録・アクセシビリティ・マイク・オートメーション）が無く、実際のキー入力・マイク・画面も使えない。
以下はユーザーが実機で確認する項目。**ここに書いた項目はどれも未検証**で、確認できたらチェックを付けて結果（数値・気づき）を書き込む。

## 0. 準備

- 確認はアプリ本体（`ContextCapture.app`）から行う。CCCapture には手で実行する診断関数があり、Wave 2（配線担当）がデバッグメニュー等から呼べるようにする:
  - `CaptureDiagnostics.runOnce(_:)` … 数秒待ってから前面コンテキストを 1 回取り、権限の状態・アプリ・ウインドウ・URL・スクショの大きさ・各項目の所要時間を JSON で標準出力と戻り値に出す。`screenshotOutputURL` を渡すと PNG を書き出す
  - `CaptureDiagnostics.runRecordingCheck(seconds:)` … `prepare()` / `start()` の所要時間、録音の長さ・ピーク・RMS・WAV の場所・レベル通知の回数
  - `CaptureDiagnostics.runHotKeyCheck(shortcut:seconds:)` … 指定秒数のあいだ押下 / 解放を記録（どの方式で登録できたか、Carbon の戻り値つき）
- 診断関数は**権限ダイアログを出さない**（状態を読むだけ。URL は許可済みのブラウザでだけ取る）。ダイアログはオンボーディング（`CapturePermissions.request*`）から出す。
- アプリのログは Console.app で `ContextCapture` を絞り込むか、Xcode から実行して標準出力を見る。

## 1. 権限の付与

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 1-1 | 初回起動で、権限をどれも付けずに `runOnce` | `permissions` が microphone=notDetermined、screen_recording=notGranted、accessibility=notGranted。app は取れる、window=null、screenshot=null、`screenshot_skip_reason`="permission_denied"。**ダイアログは出ない** | [ ] |
| 1-2 | オンボーディングからマイクを要求（`requestMicrophone`） | OS のダイアログが出て、許可で microphone=granted | [ ] |
| 1-3 | 画面収録を要求（`requestScreenRecording`）→ システム設定で ON → **アプリを再起動** | 再起動後 screen_recording=granted。再起動前は notGranted のまま（OS がプロセス内でキャッシュするため。UI でも再起動を促す） | [ ] |
| 1-4 | アクセシビリティを要求（`requestAccessibility`）→ システム設定で ON | accessibility=granted（再起動不要のはず。要確認） | [ ] |
| 1-5 | `CapturePermissions.openSettings(for:)` を 4 種で | それぞれマイク / 画面収録 / アクセシビリティ / オートメーションのペインが開く | [ ] |
| 1-6 | macOS 15 以降の「画面収録の許可を引き続き使うか」の定期確認 | 時々 OS が確認を出すのは仕様。出たら記録（頻度） | [ ] |

## 2. ホットキー（⌥Space の押下 / 解放）

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 2-1 | `runHotKeyCheck` を実行（アクセシビリティ権限**なし**） | `backend`="carbon" で登録できる。**できなければ** `error` に Carbon の戻り値（macOS 15.0〜15.1 は ⌥ だけの組み合わせを拒否する既知の挙動、-9868 など）。この OS での可否を記録 | [ ] |
| 2-2 | テキストエディタ（TextEdit）を前面にして ⌥Space を 1 秒押して離す | events に pressed → released が 1 組。`press_duration_s` ≈ 1.0、`short_press`=false。**TextEdit に文字（ノーブレークスペース）が入らない** | [ ] |
| 2-3 | ⌥Space を 3 秒押し続ける（キーリピートが起きる長さ） | pressed は 1 回だけ。released も 1 回 | [ ] |
| 2-4 | ⌥Space を素早く叩く（0.1 秒程度） | released の `short_press`=true（0.3 秒未満） | [ ] |
| 2-5 | ⌥ を押す → Space を押す → **⌥ を先に離す** → Space を離す | released が届く（押しっぱなしにならない） | [ ] |
| 2-6 | 2-1 で Carbon が失敗した場合: アクセシビリティを許可して再実行 | `backend`="eventTap"。2-2〜2-5 が同じく通る（文字が入らないことを特に確認） | [ ] |
| 2-7 | Raycast / Alfred / Spotlight 等が ⌥Space を使っている環境 | `error` が「ほかのアプリが同じショートカットを使っています」（alreadyInUse）になる、または OS 側が優先される。挙動を記録 | [ ] |
| 2-8 | ショートカットを ⌃⌥Space 等へ変更（`setShortcut`） | 新しい組み合わせで 2-2 が通り、古い ⌥Space は反応しない | [ ] |
| 2-9 | アイドル時の CPU（アクティビティモニタ、ホットキー登録のみ・録音なし） | ≤ 1%（PRD §10） | [ ] |

## 3. 前面コンテキスト（アプリ・ウインドウ・URL）

`runOnce` を実行し、待ち時間（既定 3 秒）のうちに対象アプリを前面にする。

| # | 対象 | 期待結果 | 結果 |
|---|---|---|---|
| 3-1 | Finder | app.name="Finder"、bundle_id="com.apple.finder"、window.title がフォルダ名、frame が実際の位置・大きさ（ポイント、左上原点） | [ ] |
| 3-2 | Safari（オートメーション未許可） | url=null（ダイアログは出ない）。`automation_front_browser`="notDetermined" | [ ] |
| 3-3 | アプリ本体で Safari を前面にしてキャプチャ（`.askOnFirstUse`） | 初回だけ「“ContextCapture”が“Safari”を制御」のダイアログ。許可後の 2 回目以降は url が前面タブの URL | [ ] |
| 3-4 | Google Chrome / Arc / Microsoft Edge で 3-3 と同じ | それぞれ前面タブの URL。`timings_ms.url` を記録（目安 < 300ms。超えると url=null・`url_timed_out`=true） | [ ] |
| 3-5 | ブラウザのウインドウが 0 枚（アプリだけ起動） | url=null、エラーにならない | [ ] |
| 3-6 | オートメーションを拒否したブラウザ | url=null、待たされない | [ ] |
| 3-7 | アクセシビリティなし・画面収録ありで VS Code | window.title は SCWindow 由来のタイトルで補われる（AX が無くても空にならない） | [ ] |
| 3-8 | `timings_ms.total` | 通常 < 1.5 秒。どのアプリでも 1.5 秒を大きく超えない | [ ] |

## 4. スクショ

`runOnce` に `screenshotOutputURL`（例: `~/Desktop/cc-shot.png`）を渡して画像を目視する。

| # | 対象 | 期待結果 | 結果 |
|---|---|---|---|
| 4-1 | VS Code（Electron） | フォーカス中のウインドウ 1 枚だけ。影・カーソルなし。Retina なら実ピクセル（例: 1200×800pt → 2400×1600px）。`scope`="window" | [ ] |
| 4-2 | ターミナル（Terminal / iTerm2 / Ghostty） | 同上。複数ウインドウ時は**フォーカス中**のもの | [ ] |
| 4-3 | Zoom（会議中・画面共有中） | 会議ウインドウが撮れる。撮れない場合は画面全体（`scope`="display"）にフォールバックしているか | [ ] |
| 4-4 | 同じアプリのウインドウを 2 枚並べ、後ろ側をクリックしてフォーカス | フォーカスした方が撮れる（AX の frame / タイトル照合） | [ ] |
| 4-5 | 他のウインドウが一部重なっている状態 | 重なりの無い窓そのものが撮れる（desktopIndependentWindow） | [ ] |
| 4-6 | マルチディスプレイで、サブディスプレイ上の窓 | 撮れる。フォールバック時は窓があるディスプレイ全体 | [ ] |
| 4-7 | フルスクリーン表示のアプリ | 撮れる（撮れなければ `scope`/理由を記録） | [ ] |
| 4-8 | アプリの HUD が出ている状態での画面全体フォールバック | 自アプリ（HUD）は写らない | [ ] |
| 4-9 | 画面収録の権限を外す | screenshot=null、`screenshot_skip_reason`="permission_denied"、他の項目は取れる。**ダイアログは出ない** | [ ] |

## 5. 除外アプリ（F-13）

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 5-1 | `excludedBundleIDs` に 1Password（`com.1password.1password`）を入れて、1Password 前面で `runOnce` | screenshot=null、`screenshot_skip_reason`="excluded_app"。app / window は取れる | [ ] |
| 5-2 | 除外していないアプリに切り替え | 通常どおり撮れる | [ ] |
| 5-3 | アプリ設定から除外リストを変更（`FrontmostContextCapturer.configuration` を書き換え） | 再起動なしで次のキャプチャから反映 | [ ] |

## 6. 録音

| # | 手順 | 期待結果 | 結果 |
|---|---|---|---|
| 6-1 | アプリ起動直後（`prepare()` 済み、録音していない） | メニューバーに**オレンジ（マイク使用中）の表示が出ない** | [ ] |
| 6-2 | `runRecordingCheck(seconds: 3)` で話す | `start_ms` ≤ 150（PRD §10）。duration_s ≈ 3、sample_count ≈ 48000、peak > 0.05。WAV を QuickTime で再生して自分の声が正常な速さ・高さで聞こえる | [ ] |
| 6-3 | 録音中だけオレンジ表示、stop 後に消える | そのとおり | [ ] |
| 6-4 | 話し始めの頭の言葉 | ⌥Space を押してすぐ話しても最初の音節が欠けない | [ ] |
| 6-5 | 無音で録音 | peak / rms が小さい（無音判定は配線側。値を記録） | [ ] |
| 6-6 | レベル（HUD 波形） | level_events ≈ 20 × 秒数。話すと大きく、黙ると 0 付近 | [ ] |
| 6-7 | Bluetooth ヘッドセット（AirPods 等）を**録音中に**接続 / 切断 | 落ちない。stop で、切り替え前後の音声が入った結果が返る（切り替え後の音が入らない場合も、それまでの分は残る） | [ ] |
| 6-8 | Bluetooth ヘッドセットを入力にした状態で 6-2 | 16kHz に正しく変換されている（声の高さ・速さが正常） | [ ] |
| 6-9 | Zoom / Google Meet で会議中（マイク使用中）に録音 | 両方がマイクを使える。会議側の音声が途切れない・こちらも録れる | [ ] |
| 6-10 | マイク権限を拒否して `runRecordingCheck` | error="マイクの使用が許可されていません"。落ちない | [ ] |
| 6-11 | 入力デバイスが無い Mac mini 等 | error="マイク（入力デバイス）が見つかりません"。落ちない | [ ] |

## 7. 結果の記録

- 確認日・macOS バージョン・機種:
- 2-1 の Carbon の結果（この OS で ⌥Space を Carbon で登録できるか）:
- 6-2 の `start_ms`（5 回の値）:
- 3-4 の `timings_ms.url`（ブラウザごと）:
- 気づき・不具合:
