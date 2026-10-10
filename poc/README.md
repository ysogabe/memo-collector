# PoC: ローカルモデルで Context Capture が成立するか

Apple Silicon Mac 上で以下を**完全ローカル**に動かし、アプリの成立性を測る。結果の解釈は [`docs/poc/poc-report.md`](../docs/poc/poc-report.md)、計画と合格基準は [`docs/poc/poc-plan.md`](../docs/poc/poc-plan.md)。

| モデル | 役割の仮説 | dtype |
|---|---|---|
| [LiquidAI/d1-omni-600M](https://huggingface.co/LiquidAI/d1-omni-600M) | キャプチャ時の軽量判定（意図・画面種別）、音声直接判定 | float16（bf16 は非推奨） |
| [LiquidAI/d1-3B](https://huggingface.co/LiquidAI/d1-3B) | 後段トリアージ（意図・画面種別・秘密情報） | bfloat16 |
| [google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2) | Context Inbox の検索（テキスト / 画像 / 音声） | bfloat16（f16 は非推奨） |
| mlx-community/whisper-large-v3-turbo | 日本語 STT（d1 は文字起こしできないため必須） | MLX |
| Apple Vision（`ocr.swift`） | ベースライン: OCR + 正規表現の秘密情報検知 | - |

## 構成

```
poc/
├── pyproject.toml / uv.lock / .python-version   # Python 3.12 固定（uv）
├── fixtures/
│   ├── dataset.json        # 画面 14 枚 × 注釈 30 件 + 検索クエリ（ラベルは実行前に固定）
│   ├── holdout.json        # ルール作成後に書いた未見の注釈 22 件
│   ├── screens_src/*.html  # 画面モック（秘密情報はすべてダミー）
│   ├── screens/*.png       # 1440×900 にレンダリングしたもの
│   └── audio/*.wav         # macOS say で合成した日本語音声（16kHz mono）
├── scripts/
│   ├── common.py               # 質問定義・計測ユーティリティ・モデル revision 固定
│   ├── make_fixtures.py        # フィクスチャ生成（Chrome headless + say）
│   ├── exp01_stt.py            # 日本語 STT の精度と速度
│   ├── exp02_d1.py omni|3b     # d1 の意図分類・画面種別・秘密情報検知
│   ├── exp04_embedding.py      # 埋め込み検索（テキスト / 画像 / 融合 / 音声）
│   ├── exp05_baselines.py      # ルール・埋め込みゼロショット / kNN・OCR+正規表現
│   ├── exp06_holdout_e2e.py    # ホールドアウト・全モデル常駐・解像度 vs 速度
│   └── ocr.swift               # Apple Vision OCR
└── results/                # 実験ごとの生データ JSON とログ
```

## 再現手順

```bash
cd poc
uv sync                                  # Python 3.12 + torch(MPS) + transformers>=5.15
uv run python scripts/make_fixtures.py   # 画面モックと音声を生成（Chrome が必要）
uv run python scripts/exp01_stt.py       # 以降の実験が STT 結果を使う
uv run python scripts/exp02_d1.py omni
uv run python scripts/exp02_d1.py 3b
uv run python scripts/exp04_embedding.py
uv run python scripts/exp05_baselines.py
uv run python scripts/exp06_holdout_e2e.py
```

初回はモデルを Hugging Face から取得する（合計約 11GB）。実験は MPS を取り合わないよう**1 本ずつ順番に**流すこと。

## 注意点

- **`trust_remote_code=True`**: d1 系はモデル同梱の Python コードを実行する。`common.py` で検証済みコミットに `revision` を固定している。更新する場合は差分を読んでから上げる。
- **ffmpeg 非依存**: 音声は `say --data-format=LEI16@16000` で直接 WAV を書き、Whisper には numpy 配列で渡す。
- **計測の限界**: 音声は合成音声（クリーン・読み上げ口調）、画面は HTML モック。実ユーザーの発話・実画面では STT と判定の精度は下がる前提で読むこと。サンプル数は 30 / 22 / 14 と小さく、精度は ±10pt 程度の幅で見る。
