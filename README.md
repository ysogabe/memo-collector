# memo-collector — Context Capture（仮称）

今見ている画面に、声でひと言メモを貼る macOS アプリの構想・検証リポジトリ。
ホットキーを押して話して離すだけで、スクショ・アプリ・ウインドウ・URL・自分の一言を 1 件の記録として Mac の中に残し、あとで Hermes / Claude Code に渡す。

## 構成

```
memo-collector/
├── app/                                 # macOS アプリ（XcodeGen の project.yml。`scripts/check.sh` でビルド）
├── Packages/ContextCaptureKit/          # ロジック一式の SwiftPM パッケージ（CCCore ほか、cc-models / cc-mcp）
├── docs/
│   ├── concept/source-conversation.md   # 一次ソース: 元の ChatGPT 会話の要約と、そこで決まった設計原則
│   ├── prd/PRD.md                       # プロダクト要求仕様（MVP スコープ・データモデル・アーキテクチャ）
│   └── poc/
│       ├── poc-plan.md                  # 問いと合格基準（実行前に設定）
│       └── poc-report.md                # 結果と判定、モデル別の採否
├── lp/                                  # ランディングページ（静的 HTML、FAQ 込み）
│   ├── index.html
│   └── assets/  style.css / demo.js / 画面モック画像
└── poc/                                 # ローカルモデル検証（Python 3.12 + uv）
    ├── fixtures/  dataset.json / holdout.json / 画面モック / 合成音声
    ├── scripts/   exp01〜exp06 と ocr.swift
    └── results/   実験ごとの生データ JSON
```

読む順番: `docs/concept` → `docs/poc/poc-report.md` → `docs/prd/PRD.md` → `lp/`

## LP を見る

```bash
python3 -m http.server 8791 --bind 127.0.0.1
open http://127.0.0.1:8791/lp/
```

ヒーローのボタンを長押し（または Space キーを押し続ける）すると、撮影 → 録音 → 保存 → Inbox 追加の流れを試せる。

## PoC を再現する

[`poc/README.md`](poc/README.md) を参照。
