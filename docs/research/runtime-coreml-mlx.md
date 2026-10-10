# 推論ランタイム調査: Python ヘルパー (a) から Core ML / MLX Swift (b) へ移れるか

- 対象: PRD §8.1 のモデル配置と §14 未決事項 3（推論ランタイム）
- 実施: 2026-10-08（計測時刻は各 JSON の `started_at`。UTC 09:30〜11:40）
- 環境: Apple M3 / 24GB、macOS 27、Xcode 27 / Swift 6.4。GPU は実装チームと共有しているため、レイテンシは各条件 3 周以上の中央値（周ごとの値も記録）
- 成果物はすべて `spikes/runtime/` 配下（モデル実体は `spikes/runtime/models/`、git 管理外）

## 1. 結論

### 1.1 結論表

| モデル | 経路 | 判定 | 根拠（実測） |
|---|---|---|---|
| d1-3B（テキスト意図・日時言及） | **MLX Swift**（mlx-swift-lm 3.32.3 の `LFM2`、8bit） | **条件付き Go** | PyTorch 参照との確率差 最大 0.039・top-1 一致 51/52（参照内部の tree/chain 差 0.037・51/52 と同水準）。意図 accuracy dev 25/30・未見 21/22（PyTorch と同一）。常駐メモリ 2.9GB（PyTorch MPS 6.3GB）。**条件: Swift 側トークナイザの不一致を直すこと**（下記 3.4。放置すると確率差 0.24） |
| d1-3B | MLX Swift bf16 | 条件付き Go | 数値は 8bit と同等（最大差 0.031）。メモリ 5.4GB。8bit を選ばない理由は無い |
| d1-3B | MLX 4bit | No-Go | 最大差 0.28、未見 accuracy 21/22 → 19/22 に低下 |
| d1-3B | Core ML（GPU, fp16, 5 分割） | 条件付き Go（推奨しない） | 変換・数値は成立（最大差 0.027、accuracy 同一、2 問で 0.45 秒）。ただし系列長が可変だと形状ごとに再コンパイルされ GPU メモリが 15GB 超まで膨張しスワップを使い切った。固定長バケット化で 8GB 前後。MLX より手間が多く利点が無い |
| d1-3B | Core ML（ANE） | No-Go | `CPU_AND_NE` で 6 層チャンクの読み込み直後にプロセスが SIGSEGV（可変長 RangeDim）。2.6B を ANE に載せる設計変更（静的形状・層分割の作り直し）が必要で、効果も見込みにくい |
| d1-3B | GGUF + llama.cpp | 未検証（有力な代替） | 公式 `LiquidAI/d1-3B-GGUF`（Q8_0/Q4_K_M/BF16 + mmproj）があり、llama-server に `/v1/systemone` が実装されていると README に記載。決定 API と画像入力をそのまま保てる。数値一致は未測定 |
| EmbeddingGemma 2（テキスト） | **MLX Swift（手書き移植、~150 行）** | **Go** | PyTorch 参照とのコサイン最小 0.9981（50 文）、Recall@3 / MRR が参照と完全一致（768: 0.883/0.900、256: 0.883/0.850）。1 文 13ms（PyTorch MPS 34ms）。ピーク 0.59GB。Swift トークナイザ一致 50/50 |
| EmbeddingGemma 2（画像・融合） | MLX（Python, mlx-vlm main） | 条件付き Go | 画像コサイン最小 0.9989、融合 0.9995、検索指標は参照と一致（融合 256: R@3 0.933 / MRR 0.950）。画像 0.55 秒（PyTorch 0.77 秒）。**Swift では未移植**（mlx-swift-lm の Gemma4 視覚塔を流用して移植する工数が要る） |
| EmbeddingGemma 2 | Core ML | 未検証 | テキスト塔は小さく変換は現実的と見込むが未実施（MLX Swift で足りたため優先度を下げた） |
| STT | **WhisperKit 1.1.0**（large-v3-turbo, Core ML/ANE） | **Go** | CER 7.72%（PoC mlx-whisper 7.47% plain / 7.35% 語彙プロンプト）、p50 1.34 秒（PoC 1.04 秒）、RSS 1.5GB。**語彙プロンプト（promptTokens）は出力に反映されなかった**（30 件すべて同一出力）。初回ロード 58 秒（ANE 特殊化）、2 回目以降 4 秒 |
| STT | FluidAudio 0.17.7 Parakeet JA（`tdtJa`, ANE） | No-Go（精度） | CER 19.3%、p50 0.04 秒、RSS 0.15GB。英語の固有名詞・技術語で崩れる（Hermes→「1rmes」、リファクタリング→「短くアレンジ」）。速度は桁違いに良いので、語彙バイアスが効けば再評価の余地あり（未検証） |

### 1.2 推奨構成

**(a) Python ヘルパーから (b) へ移るべき。順序は EmbeddingGemma 2（テキスト）→ STT → d1-3B。**

1. **EmbeddingGemma 2 テキスト埋め込みを最初に MLX Swift へ**（工数 2〜3 人日）。移植済みスパイクがそのまま数値一致しており、リスクが最も低い。テキスト検索だけなら Python が不要になる。画像・融合埋め込みは mlx-swift-lm の `MLXVLM/Gemma4` 視覚塔 + プロセッサを流用して移植（+4〜6 人日、未検証）。それまで融合インデックスは Python 側に残すか、テキスト + メタの索引で代替（PoC で 768 次元なら R@3 は同値 0.883）。
2. **STT は WhisperKit に置き換え**（2〜3 人日）。CER はほぼ同等、Python 不要、ANE で GPU を d1 と取り合わない。語彙プロンプトが効かない件だけ要調査（効かなくても PoC 比 +0.4pt）。初回 58 秒の ANE 特殊化はオンボーディング中に済ませる。
3. **d1-3B は MLX Swift 8bit へ**（4〜6 人日）。前提作業: (i) プロンプト組み立てと readout（`prompt.py` の `render` / `readout_ids` / `readout`）の Swift 移植、(ii) トークナイザ不一致の修正、(iii) 読み込み形式（下記 3.3 の抽出・`block_ff_dim` 追記）を変換パイプラインに入れる。画像入力が必要になったら mlx-swift-lm の `LFM2VL` を検証（未検証）。
4. Core ML は d1 には使わない。ANE を使いたいのは STT（WhisperKit が既に担う）だけ。

この順で移すと、Python ヘルパーは d1 だけを抱えた状態を経て最終的に不要になる。全体の移行工数見積りは **約 10〜15 人日**（画像埋め込みの Swift 移植を含めると +4〜6 人日）。

**実装チームへの前提条件**: このマシンの Xcode 27 には Metal Toolchain が入っていないため、MLX Swift を含むアプリは `xcodebuild -downloadComponent MetalToolchain` を済ませないとビルドできない（スパイクは Python mlx 同梱の metallib を流用する細工で回避した。製品では不可）。

メモリ面の効果: PRD §8.1 の「3 つ同時常駐で MPS 約 11GB」は、d1 8bit 2.9GB + EmbeddingGemma 2 テキスト塔 0.6GB（全モダリティでも 1.5〜2.3GB）+ WhisperKit 1.5GB ≒ **5〜7GB** になり、d1 の 10 分解放ルールを緩められる見込み（同時常駐での実測は未実施）。

## 2. d1-3B の「決定ヘッド」の正体

`modeling_d1.py` / `runner.py` / `prompt.py` / `hybrid.py` / `lfm2_vl.py`（revision 051bcc4）を読んだ結果:

- **別ヘッドは無い**。`answer()` は LFM2-VL の通常の `lm_head`（`tie_word_embeddings=true` なので埋め込み行列そのもの）で最終トークン位置の logits を出す。
- `prompt.readout()` が、選択肢ごとの単一トークン ID 群を max-pool し、**その数個だけで softmax** する。全語彙の logsumexp は打ち消し合うので、確率は選択肢トークンの logits だけで決まる。
  - choice（意図 5 択）: 選択肢コード `A`〜`E` と ` A`〜` E`（ID 例: [41,334],[42,378],…）
  - noul（日時言及）: yes 側 `yes/Yes/YES`、no 側 `no/No/NO` の単一トークン形
- `hybrid.py` の Tree は「状態を 1 回だけ読んで複数質問を分岐させる」効率化で、数学的には 1 質問 1 forward と同じ（参照実測でも tree と chain の差は最大 0.037）。出力トークン 0、KV キャッシュ不要。
- したがって **最終位置の logits（あるいは最終 hidden と選択肢トークンの埋め込み行 ≤12 本の内積）を出せるランタイムなら API ごと再現できる**。量子化版（MLX / GGUF）も API は保たれ、問題は数値ずれだけ。
- `calibration` は既定 None（d1 の `D1Model.engine` は渡していない）ので、Swift 側に較正の移植は不要。

プロンプト（d1 の既定 `json_only`・system なし）は次の形で、Swift 側で文字列として組み立てればよい:

```
<|startoftext|><|im_start|>user\n{state}\n\n\nQUESTION:\n{instructions}\n\nOptions:\nA {desc}\n...\n\nReply with the option code only.<|im_end|>\n<|im_start|>assistant\n
```

## 3. 数値一致・精度・レイテンシ・メモリ・ディスク

### 3.1 d1-3B（テキスト: INTENT_Q_EN + DEADLINE_Q、dev 30 + 未見 22 = 52 件）

参照は PyTorch MPS bf16（`data/d1_reference_mps_bf16.json`）。「chain」は 1 質問 1 forward、「tree」は PoC と同じ `system_one(text, {intent, deadline})`。
**ノイズ床: PyTorch 内の tree vs chain が最大 |Δp| 0.0371、top-1 一致 51/52。**

| 経路 | 意図 最大\|Δp\| vs chain（top-1） | vs tree（top-1） | 日時 最大\|Δp\| | 意図 acc dev / 未見 | 日時 acc dev | 1 件(2 問) レイテンシ 3 周の中央値 | メモリ（ロード後 / ピーク） | ディスク |
|---|---|---|---|---|---|---|---|---|
| PyTorch MPS bf16（参照） | — | — | — | 26/30（chain）25/30（tree）/ 21/22 | 28/30 | tree 0.40 秒（0.40/0.40/0.58）、1 問のみ 0.54 秒 | MPS 6.3GB（driver 7.3GB） | 5.8GB（視覚塔込み） |
| MLX Python bf16 | 0.0308 (51/52) | 0.0290 (52/52) | 0.0083 | 25/30 / 21/22 | 28/30 | 0.81 秒（0.79/0.82/0.81） | 5.4GB / 5.5GB | 5.0GB |
| MLX Python 8bit | 0.0386 (51/52) | 0.0325 (52/52) | 0.0092 | 25/30 / 21/22 | 28/30 | 0.80 秒（0.80/0.83/0.79） | 2.9GB / 3.1GB | 2.7GB |
| MLX Python 4bit | 0.2753 (48/52) | 0.2760 (49/52) | 0.0377 | 26/30 / **19/22** | 28/30 | 0.76 秒 | 1.5GB / 1.9GB | 1.4GB |
| **MLX Swift bf16** | 0.0308 (51/52) | 0.0290 (52/52) | 0.0083 | 25/30 / 21/22 | （Python と同値） | 0.54 秒（0.52/0.54/0.86）※ 2 回目 0.65 秒 | 5.4GB / 5.6GB、RSS 5.5GB | 5.0GB |
| **MLX Swift 8bit** | 0.0386 (51/52) | 0.0325 (52/52) | 0.0092 | 25/30 / 21/22 | （同上） | 0.75 秒（0.75/0.77/0.73）※ | 2.9GB / 3.3GB、RSS 3.0GB | 2.7GB |
| MLX Swift 4bit | 0.2753 (48/52) | 0.2760 (49/52) | 0.0377 | 26/30 / 19/22 | （同上） | 0.71 秒 | 1.5GB / 2.1GB | 1.4GB |
| MLX Swift bf16 + **Swift トークナイザ** | 0.2161 (51/52) | 0.2377 (50/52) | 0.0341 | 25/30 / 21/22 | — | — | — | — |
| Core ML GPU fp16（5 分割、64/160 バケット） | 0.0270 (51/52) | 0.0150 (52/52) | 0.0090 | 25/30 / 21/22 | — | 0.45 秒（先頭 20 件, 0.45/0.46/0.47） | プロセス footprint 約 8GB（可変長のままだと 17GB） | 5.2GB |

- Swift と Python の MLX は確率が小数 5 桁まで同一（同じ MLX カーネル）。
- ※ Swift のレイテンシは GPU 共有のため周ごとのぶれが大きい（2 回目の計測は `results/d1_swift_*_run2.json`、3.1.1）。150 トークン前後の prefill は計算律速で、量子化しても速くならない（8bit/4bit の利点はメモリのみ）。
- 2 問を右パディングで 1 バッチにまとめても速くならなかった（Swift bf16 0.94 秒、確率差 ≤0.009）。トークン数が倍になるだけなので当然で、PyTorch の tree のように状態を共有しても節約は 1 割程度（状態部分 ~25 トークン / 合計 ~210）。非同期処理なので 0.5〜0.8 秒で実用上問題ない。
- 4bit は意図の確率が最大 0.28 動き、未見データで 2 件誤る。**8bit を推奨**。

#### 3.1.1 Swift レイテンシ 2 回目

| 経路 | 1 回目（UTC 09:52〜10:03） 3 周の中央値 | 2 回目（UTC 11:24〜11:33） | 2 問 1 バッチ（2 回目） |
|---|---|---|---|
| Swift bf16 | 0.52 / 0.54 / 0.86 秒 | 0.51 / 0.65 / 0.96 秒 | 0.88 / 0.90 / 0.92 秒 |
| Swift 8bit | 0.75 / 0.77 / 0.73 秒 | 0.74 / 0.73 / 0.73 秒 | 0.93 / 0.94 / 0.96 秒 |

bf16 は 1 周目が最速で周を追うごとに遅くなる（共有 GPU の負荷か発熱かは未切り分け）。8bit は 0.73〜0.77 秒で安定。いずれも PyTorch tree（0.40 秒）より遅いが、非同期処理（PRD §8.1）なので許容範囲と判断する。数値は 2 回目も 1 回目と完全に同一。

### 3.2 EmbeddingGemma 2（PyTorch 参照: sentence-transformers 6.1、MPS bf16、exp04 と同じ入力組み立て）

| 経路 | コサイン（最小）doc / query / 画像 / 融合 | Recall@3 / MRR（768） text→capture | （256） text→capture | 融合 256 | 画像のみ 768 | 1 文 / 1 クエリ | 画像 1 枚 / 融合 1 件 | メモリ | ディスク |
|---|---|---|---|---|---|---|---|---|---|
| PyTorch MPS（参照） | — | 0.883 / 0.900 | 0.883 / 0.850 | 0.933 / 0.950 | 0.800 / 0.731 | 34ms / 32ms | 0.77 秒 / 0.77 秒（exp04） | MPS 1.5GB（driver 2.7GB） | 1.4GB |
| MLX Python bf16（mlx-vlm main） | 0.9998 / 0.9999 / 0.9989 / 0.9995 | 0.883 / 0.900 | 0.883 / 0.850 | **0.933 / 0.950** | 0.800 / 0.729 | 13ms / 8.7ms | 0.55 秒 / 0.56 秒 | 1.5GB / ピーク 2.3GB | 1.4GB |
| MLX Python 8bit（言語塔のみ量子化） | 0.9994 / 0.9998 / 0.9986 / 0.9993 | 0.883 / 0.900 | 0.883 / 0.850 | 0.933 / 0.950 | 0.800 / 0.731 | 14ms / 9.3ms | 0.57 秒 / 0.60 秒 | 1.2GB / 2.0GB | — |
| **MLX Swift（テキスト塔の手書き移植）** | 0.9981 / 0.9982（画像検索用クエリ 0.9984） / 未移植 / 未移植 | **0.883 / 0.900** | **0.883 / 0.850** | 未移植 | 未移植 | 13ms（13.1/13.2/13.0） | — | ピーク 0.59GB | 0.55GB（テキスト塔のみ） |

- 融合 768 の MRR は MLX 0.950 vs 参照 0.900（R@3 は同値）。ランキング下位の入れ替わり 1 件程度で、コサインは 0.9995。
- 8bit は効果が小さい（言語塔は 0.3B 相当で、メモリの大半は視覚・音声塔と埋め込み表）。bf16 のままでよい。モデルカードの指示どおり f16 にはしない。

### 3.3 STT（fixtures/audio 30 件、CER は `poc/scripts/common.py` の `cer()` で採点）

| 経路 | 平均 CER | p50 / p90 レイテンシ（3 周の各ファイル中央値） | ロード | RSS | ディスク |
|---|---|---|---|---|---|
| mlx-whisper large-v3-turbo（PoC, plain） | 7.47% | 1.04 秒 / — | — | — | 1.6GB |
| mlx-whisper（PoC, 語彙プロンプト） | 7.35% | 1.12 秒 / 1.17 秒 | — | — | 同上 |
| **WhisperKit `openai_whisper-large-v3-v20240930`（plain）** | **7.72%** | 1.34 秒 / 1.43 秒 | 初回 58 秒・2 回目 4.2 秒 | 1.5GB | 1.5GB |
| WhisperKit（語彙プロンプトを promptTokens で付与） | 7.72%（出力が plain と 30/30 同一） | 1.37 秒 / 1.45 秒 | 4.2 秒 | 1.5GB | 同上 |
| FluidAudio Parakeet JA（`tdtJa`, int8 encoder） | 19.31% | **0.04 秒** / 0.05 秒 | 91 秒（初回 DL 込み） | 0.15GB | 0.6GB |

## 4. 経路ごとの詳細と阻害要因

### 4.1 MLX（Python / Swift）で d1 を動かすために必要だったこと

1. **言語モデルだけを抽出**（`scripts/d1_extract_text.py`）。d1 の checkpoint は transformers v5 の LFM2-VL 形式（`model.language_model.*`）で、mlx-lm の `lfm2-vl` ローダが期待する名前と合わない。`model.language_model.X → model.X` に改名し `text_config` をトップレベル config にした（重みの値は無変更）。
2. **`block_ff_dim` を config に追記**。mlx-swift-lm 3.32.3 の `LFM2Configuration` は `intermediate_size` を読まず、無いと FFN 次元を hidden_size(2048) とみなして `w2` の形状不一致で落ちる（Python の mlx-lm は `intermediate_size` を読む）。上流へ直す価値のある小さなバグ。
3. 量子化は `mlx_lm convert -q --q-bits {8,4} --q-group-size 64`。Swift は `loadWeights(..., quantization:)` がそのまま読む。
4. Swift は `LFM2Model(cfg)(ids, cache: nil)` の 1 forward。最終位置の logits から選択肢 ID を拾うだけ（`swift/D1Spike/Sources/d1-swift/main.swift`）。

### 4.2 Swift トークナイザの不一致（d1 の Go 条件）

> **2026-10-10 追記（実装で判明した根本原因）**: 下記の `ignore_merges` 仮説は誤り。swift-transformers 1.3.4 は前分割を `String.range(of:options:.regularExpression)` で行い、macOS 27 の Foundation ではこれが書記素クラスタ単位で照合するため、文字クラス `[\r\n]` が単独の LF に一致しない（CRLF にのみ一致）。製品では `CCIntent/D1Tokenizer.swift`（NSRegularExpression で UTF-16 単位に照合する自前実装）で解決し、参照 104/104 と追加 94 入力で HF と一致した。

- swift-transformers 1.3.4 の `AutoTokenizer` で d1 のプロンプトを encode すると **104/104 件で HF と不一致**。状態テキストだけなら 52/52 一致する。
- 原因箇所: テンプレート内の `"\n\n\n"`（状態ブロック末尾 + `\nQUESTION:`）。HF は 1 トークン `ĊĊĊ`、Swift は `ĊĊ` + `Ċ` に分ける。同じ前分割パターンを NSRegularExpression 単体で試すと HF と同じ分割（`"\n\n\n"` が 1 片）になったので、差は **BPE マージ段と推定**する（このトークナイザは `ignore_merges: true`。swift-transformers の Split 前分割が実際に同じ経路を通るかは未確認。根本原因の特定は未完了）。
- 影響: Swift トークン列で推論すると確率差が最大 0.24（accuracy は今回の 52 件では不変）。**放置不可**。
- 対処案（いずれも未実装）: (1) swift-transformers の BPE に `ignore_merges`（前分割片が語彙にあればそのまま採用）を入れる（〜0.5 人日 + 上流 PR）、(2) テンプレート部分のトークン ID を定数で持ち、ユーザー文だけを encode して連結（ただし句読点で終わる文は後続の改行と同じ前分割片にまとまるため境界処理が要る）。(1) を推奨。
- EmbeddingGemma 2（Gemma トークナイザ）では Swift と HF が 50/50 一致した。

### 4.3 Core ML（d1）

- 方法: `hybrid.py` の tree=None 経路と同じ計算を、Core ML が下ろせる演算（明示 causal mask の matmul、depthwise conv1d、half-split RoPE）で書いた最小 torch 実装を coremltools 9.0 / torch 2.7.0 で mlprogram（fp16、iOS18/macOS15 ターゲット）に変換（`scripts/d1_coreml_probe.py`）。
  - **lm_head は変換しない**: readout に要るのは選択肢トークン ≤12 本の埋め込み行との内積だけなので、出力は最終 hidden（2048）。128000×2048 の出力層を省ける（MLX 側でも同じ最適化が可能）。
  - KV キャッシュ・ステートフルモデルは不要（出力トークン 0）。
- 変換時の落とし穴: `torch.arange(T)`・`view(1, T, …)`・`groups=x.shape[1]`・`repeat_interleave` が trace で `aten::Int` を生み coremltools が落ちる → cumsum で位置を作る / `-1` で reshape / Python int を保持 / expand+reshape に置換。
- 3 層スライス（conv, conv, attention）で fp16 の Core ML と fp32 torch のコサイン 0.999998（T=17, 150）。
- 全 30 層を 6 層 × 5 チャンクに分割（各 0.9〜1.4GB、変換 2.4 分、**変換時のピーク RSS 16.5GB**）。
- **可変長（RangeDim 1..512）の問題**: 新しい系列長ごとに MPSGraph の特殊化が走り（6 層チャンクで 0.7〜1.9 秒/形状）、52 件の評価でプロセスの GPU メモリが 15GB を超え、マシンのスワップ 16GB を使い切って実質停止した（共有マシンのため中断）。**64 / 160 トークンの 2 バケットに右パディング**し、最終チャンクを全位置出力版にして実長−1 の位置を読む方式で解決（footprint 約 8GB、2 問 0.45 秒）。
- **ANE（CPU_AND_NE）は SIGSEGV**（exit 139）。2.6B を ANE 向けに作り直す（静的形状・Conv2d 化・層分割）工数は 1〜2 週間規模と見積もり、効果も不確か。
- 製品で Core ML を選ぶなら、バケット形状の列挙（`EnumeratedShapes`）で作り直す・初回特殊化をオンボーディングで済ませる、が必要。MLX Swift に対する利点は今回見つからなかった。

### 4.4 GGUF / llama.cpp（未検証）

`LiquidAI/d1-3B-GGUF` は Liquid AI 公式。README によれば `llama-server -hf LiquidAI/d1-3B-GGUF:Q8_0` で起動し `/v1/systemone` に state / questions / images を投げる。決定 API・画像入力を保ったまま C/C++ ライブラリとして組み込めるので、MLX Swift のトークナイザ修正やプロンプト移植を避けたい場合の代替になる。ただし llama.cpp の当該エンドポイントの実装（readout が d1 と同一か）と数値一致は未確認。

### 4.5 EmbeddingGemma 2

- アーキテクチャは `embedding_gemma2`（Gemma 4 系: 層ごとの head_dim/kv_heads 上書き、Per-Layer Embeddings、v_norm、layer_scalar、sliding 512、双方向、出力 512→768 射影 → mean pooling → L2 正規化）。
- mlx-swift-lm 3.32.3 / main とも `MLXEmbedders` は Gemma3 まで。**embedding_gemma2 は無い**。Python は mlx-vlm 0.7.6（PyPI 最新）に無く、main（`fdd94f3`）に入っている。
- そこで mlx-vlm の `language.py` を仕様に、テキスト塔を MLX Swift の素の演算で書いた（`swift/D1Spike/Sources/embed-swift/main.swift`、約 150 行）。初回で数値一致した。製品化には sliding mask（512 トークン超の入力）とバッチ・パディングの実装が残る。
- 画像・融合は Python MLX で一致を確認済み。Swift で使うには mlx-swift-lm の `MLXVLM/Models/Gemma4.swift` の視覚塔・`MultimodalEmbedder` と、Gemma4 画像プロセッサ（`do_normalize: false`、280 トークン）を流用・移植する。

### 4.6 STT

- WhisperKit: SwiftPM で素直に入る。モデルは `argmaxinc/whisperkit-coreml` の `openai_whisper-large-v3-v20240930`（= large-v3-turbo、1.5GB）。初回ロードで ANE 向け特殊化に 58 秒かかる（2 回目 4 秒）。`DecodingOptions.promptTokens` に PoC と同じ語彙プロンプトを入れても出力が 1 文字も変わらなかった（設定の誤りか WhisperKit 側の扱いかは未切り分け）。
- FluidAudio: `AsrModelVersion.tdtJa`（NVIDIA `parakeet-tdt_ctc-0.6b-ja` の Core ML 版）が実在し、Swift から 3 行で動く。極めて速いが、英語混じりの技術メモで CER が 2.6 倍。FluidAudio の CustomVocabulary（CTC 再スコア）を試す余地はある（未検証）。
- ビルドの注意: FluidAudio は GitHub Releases のバイナリ（NemoTextProcessing.xcframework, 87MB）を取りに行き、SwiftPM がキーチェーン照会で**無言のまま停止**する（非対話環境）。`swift build --disable-keychain` で回避。

## 5. ライセンスと配布

| モデル | ライセンス（実物で確認） | アプリ同梱 | 初回ダウンロード | 注意 |
|---|---|---|---|---|
| d1-3B（と派生の 8bit 変換物） | **LFM Open License v1.0**（`LICENSE` 本文）。Apache 2.0 型の再配布条件（ライセンス写しの同梱、改変ファイルへの改変告知、帰属表示の保持）＋ **§5 商用利用制限: 年間売上 1,000 万米ドル以上の法人の商用利用は許諾外** | 可（閾値未満の事業者なら）。量子化・抽出物は派生物なので LICENSE 同梱と改変告知が必要（スパイクの抽出物には `NOTICE-MODIFIED.txt` を置いた） | 可（同条件） | 閾値はアプリ提供者だけでなく**利用者の法人**にも効くかが読み取りにくい（"Any Commercial Use … by a Legal Entity that exceeds the Threshold is not licensed"）。大企業ユーザーへの配布は法務確認が要る |
| EmbeddingGemma 2 | モデルカード `license: apache-2.0`。リンク先 `ai.google.dev/gemma/docs/gemma_4_license` の本文も Apache License 2.0 そのもの（Gemma Terms of Use ではない） | 可（ライセンス写し・NOTICE） | 可 | 同ページのメニューに Prohibited Use Policy へのリンクはあるが、Gemma 4 に適用されるかはページから読み取れなかった（未確認） |
| Whisper large-v3-turbo / WhisperKit / whisperkit-coreml | MIT（モデル・ライブラリとも） | 可 | 可 | — |
| FluidAudio | Apache-2.0 | 可 | — | 依存の NemoTextProcessing バイナリのライセンスは未確認 |
| Parakeet TDT-CTC 0.6B JA | CC-BY-4.0（NVIDIA 原本・FluidInference 版とも） | 可（帰属表示が必要） | 可 | — |

サイズの目安（同梱判断用）: d1 8bit 2.7GB、EmbeddingGemma 2 全体 1.4GB（テキスト塔のみ 0.55GB）、WhisperKit turbo 1.5GB。合計 4〜5GB で、アプリ同梱より初回ダウンロード（チェックサム検証つき）が現実的。

## 6. 再現手順（`spikes/runtime/` で実行）

```zsh
cd spikes/runtime
# 0) Python 環境（poc/.venv は参照実行のみ。追加依存は独自 venv）
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r pyproject.toml   # mlx-lm 0.32.0 / mlx-vlm 0.7.6
uv venv --python 3.12 .venv-coreml && uv pip install --python .venv-coreml/bin/python coremltools==9.0 torch==2.7.0 safetensors numpy
uv venv --python 3.12 .venv-embed && uv pip install --python .venv-embed/bin/python \
  "mlx-vlm @ git+https://github.com/Blaizzy/mlx-vlm.git@$(cat data/mlx_vlm_embed_sha.txt)" mlx==0.32.3 "transformers>=5.18" pillow numpy psutil
D1=~/.cache/huggingface/hub/models--LiquidAI--d1-3B/snapshots/051bcc464b01b9f92942b364d9586b0ef5912432
EG=$(ls -d ~/.cache/huggingface/hub/models--google--embeddinggemma-2/snapshots/*)

# 1) d1 参照（PyTorch MPS）
HF_HUB_OFFLINE=1 ../../poc/.venv/bin/python -I scripts/d1_reference.py ../.. data/d1_reference_mps_bf16.json mps
# 2) 言語モデル抽出 + 量子化
.venv/bin/python -I scripts/d1_extract_text.py $D1 models/d1-3b-text-bf16
for b in 8 4; do .venv/bin/python -m mlx_lm convert --hf-path models/d1-3b-text-bf16 --mlx-path models/d1-3b-text-q$b -q --q-bits $b --q-group-size 64; done
python3 scripts/d1_patch_config.py models/d1-3b-text-q8 models/d1-3b-text-q4   # convert が書き直した config に block_ff_dim を追記
# 3) MLX Python
for m in bf16 q8 q4; do .venv/bin/python -I scripts/d1_mlx_eval.py data/d1_reference_mps_bf16.json models/d1-3b-text-$m results/d1_mlx_py_$m.json; done
# 4) MLX Swift（Metal Toolchain が無い環境向けの細工込み）
scripts/build_d1spike.sh
for m in bf16 q8 q4; do swift/D1Spike/.build/release/d1-swift data/d1_reference_mps_bf16.json models/d1-3b-text-$m results/d1_swift_$m.json; done
D1_USE_SWIFT_TOKENS=1 swift/D1Spike/.build/release/d1-swift data/d1_reference_mps_bf16.json models/d1-3b-text-bf16 results/d1_swift_bf16_swifttok.json
D1_TOKENIZER_ONLY=1   swift/D1Spike/.build/release/d1-swift data/d1_reference_mps_bf16.json models/d1-3b-text-bf16 results/d1_swift_tok.json
# 5) Core ML（変換はピーク RSS 16.5GB。共有マシンでは他の重い処理と重ねない）
.venv-coreml/bin/python -I scripts/d1_coreml_probe.py slice    models/d1-3b-text-bf16 models/coreml-d1
.venv-coreml/bin/python -I scripts/d1_coreml_probe.py full     models/d1-3b-text-bf16 models/coreml-d1 5
.venv-coreml/bin/python -I scripts/d1_coreml_probe.py last_all models/d1-3b-text-bf16 models/coreml-d1
.venv-coreml/bin/python -I scripts/d1_coreml_probe.py eval     models/d1-3b-text-bf16 models/coreml-d1 data/d1_reference_mps_bf16.json results/d1_coreml_CPU_AND_GPU.json CPU_AND_GPU
.venv-coreml/bin/python -I scripts/d1_coreml_shape_probe.py models/coreml-d1 CPU_AND_GPU results/d1_coreml_shape_gpu.json
# 6) EmbeddingGemma 2
HF_HUB_OFFLINE=1 ../../poc/.venv/bin/python -I scripts/embed_reference.py ../.. data/embed_reference.npz
for q in bf16 q8; do HF_HUB_OFFLINE=1 .venv-embed/bin/python -I scripts/embed_mlx_eval.py $EG data/embed_reference.npz ../../poc/fixtures/dataset.json results/embed_mlx_$q.json $([ $q = q8 ] && echo q8); done
HF_HUB_OFFLINE=1 .venv-embed/bin/python -I scripts/embed_export_ids.py $EG data/embed_reference.npz data/embed_text_ids.json
.venv-embed/bin/python -I scripts/embed_extract_text.py $EG models/embeddinggemma2-text
swift/D1Spike/.build/release/embed-swift models/embeddinggemma2-text data/embed_text_ids.json results/embed_swift_bf16.json
.venv-embed/bin/python -I scripts/embed_swift_score.py data/embed_text_ids.json results/embed_swift_bf16.json ../../poc/fixtures/dataset.json
# 7) STT
(cd swift/STTSpike && swift build -c release --disable-keychain)
swift/STTSpike/.build/release/stt-swift whisperkit  ../../poc/fixtures/audio models/stt results/stt_whisperkit_plain.json
WHISPER_PROMPT=1 swift/STTSpike/.build/release/stt-swift whisperkit ../../poc/fixtures/audio models/stt results/stt_whisperkit_prompt.json
swift/STTSpike/.build/release/stt-swift parakeet-ja ../../poc/fixtures/audio models/stt results/stt_parakeet_ja.json
../../poc/.venv/bin/python -I scripts/stt_score.py ../.. results/stt_whisperkit_plain.json results/stt_whisperkit_prompt.json results/stt_parakeet_ja.json
```

依存の版: mlx 0.32.3 / mlx-swift 0.32.3 / mlx-swift-lm 3.32.3 / swift-transformers 1.3.4 / mlx-lm 0.32.0 / mlx-vlm 0.7.6（d1）・main `fdd94f3`（EmbeddingGemma 2）/ coremltools 9.0 + torch 2.7.0 / WhisperKit 1.1.0 / FluidAudio 0.17.7。

ディスク使用（`spikes/runtime/models/`）: d1 抽出 bf16 5.0GB・8bit 2.7GB・4bit 1.4GB、Core ML 6.9GB、EmbeddingGemma 2 テキスト塔 0.55GB、STT 2.1GB。合計約 19GB（不要になれば `models/` ごと削除可）。新規ダウンロードは STT モデル 2.1GB と依存パッケージのみ。

## 7. 未検証事項とリスク

- **d1 の Swift トークナイザ修正**（4.2）は未実装。根本原因（BPE マージ段 / `ignore_merges`）も仮説段階。
- d1 の**画像入力**（LFM2-VL）は MLX Python / Swift とも未検証。PRD §8.1 では d1 はテキストのみなので現時点の必須ではない。mlx-swift-lm に `LFM2VL` はある。
- d1 の**全層 Core ML の ANE 実行**、Core ML の `EnumeratedShapes` 版は未実施。
- GGUF / llama.cpp の `/v1/systemone` の数値一致は未測定。
- **3 モデル同時常駐のメモリ・遅延**（PRD の 11GB 問題の再測定）は未実施。個別値の合算での推定のみ。
- EmbeddingGemma 2 の**音声埋め込み**、画像・融合の **Swift 移植**、512 トークン超の sliding mask、バッチ処理は未実装。
- WhisperKit の**語彙プロンプトが効かない**原因は未切り分け。FluidAudio の語彙バイアスも未検証。
- レイテンシは GPU を実装チームと共有した状態での値で、周ごとのぶれが最大 1.6 倍ある（Swift bf16: 0.52/0.54/0.86 秒）。製品判断に使うなら占有状態で再計測すること。
- ビルド環境: このマシンの Xcode には **Metal Toolchain が入っておらず**、MLX Swift は `xcodebuild -downloadComponent MetalToolchain` を入れるか、本スパイクのように Python mlx 同梱の `mlx.metallib` を流用する必要がある（後者は版ずれで壊れるので製品では不可）。
- **共有マシンへの影響**: Core ML 変換（ピーク RSS 16.5GB）と可変長評価（GPU 15GB 超、スワップ 16GB を使い切り）で、UTC 10:20〜11:10 ごろ実装チームの作業を遅くした可能性が高い。
- **ディスク**: `spikes/runtime/models/` は約 19GB で、指示の 20GB 上限に近い。8bit 経路だけ残すなら `models/d1-3b-text-bf16`（5.0GB、ただし再量子化の元）、`models/d1-3b-text-q4`（1.4GB）、`models/coreml-d1`（6.9GB、うち `slice3.mlpackage` 0.96GB）は削除してよい。
- ライセンス: LFM Open License の売上閾値が「利用者の法人」に及ぶかの解釈は法務確認が要る。
