# macOS更新時のOCR変化とガード回帰の切り分け（#5）

対象は`poc/fixtures/screens/s01.png`〜`s14.png`の著作した合成画像だけ。個人の画面・媒体・OCR本文を診断用に保存しない。

1. OSを更新する前に、入力画像を同じcommitに固定し、以下でローカルの診断JSONを保存する。
2. 更新後に同じsource/画像/言語設定で再実行する。画像SHA256とVision request revision、OSを確認する。
3. 同じidのOCR行のtext SHA256とbboxを比較する。画像hashが同じでOCR行hash/bboxが変わっていれば、OCR出力の変化がある。hashは本文を復元するためのものではない。
4. `SecretDetectorTests`と`SecretMaskerTests`（固定OCR行/矩形）も実行する。同じ固定入力で結果が変わればdetector/masker側の回帰を調べる。14画像の検出だけを見て正規表現を広げない。
5. 実画像の`VisionSecretScannerTests`では4/4検出・誤検知0と、各秘密値のbbox/マスクを確認する。OCR変更に対応する修正でも、既知のnegative fixtureの誤検知とマスク漏れを増やさない。
6. baseline更新は入力とOCRの差、検出影響、固定入力テストの結果をPRへ記録してから行う。失敗した新結果をそのまま正解へ置き換えない。

```sh
CC_OCR_REPORT_OUT=/tmp/cc-ocr-before.json \
  swift test --package-path Packages/ContextCaptureKit --filter OCRFixtureDiagnosticsTests
swift test --package-path Packages/ContextCaptureKit \
  --filter 'SecretDetectorTests|SecretMaskerTests|VisionSecretScannerTests'
```

出力は画像hash、OCR行hashと位置、finding kindと位置、OS/revision。OCR本文・個人DBは出力しない。上のコマンドはモデルの重みやネットワークを使わない。
