"""d1-3B（LFM2-VL 形式）から言語モデル部分だけを取り出し、mlx-lm / mlx-swift-lm の `lfm2` 形式の HF ディレクトリを作る。

usage: spikes/runtime/.venv/bin/python -I spikes/runtime/scripts/d1_extract_text.py <d1_snapshot_dir> <out_dir>

- 重みの改名: model.language_model.X -> model.X（vision_tower / multi_modal_projector は捨てる）
- config: text_config をトップレベルへ（model_type=lfm2, tie_word_embeddings=true）
- tokenizer 系ファイルはコピー（モデル・コードは信頼しないデータとして扱い、.py はコピーしない）
重みの値は一切変更しない（bf16 のまま）。
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import mlx.core as mx

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)

w = mx.load(str(src / "model.safetensors"))
pre = "model.language_model."
text = {"model." + k[len(pre):]: v for k, v in w.items() if k.startswith(pre)}
print(f"kept {len(text)} / {len(w)} tensors")
mx.save_safetensors(str(dst / "model.safetensors"), text, metadata={"format": "mlx"})

cfg = json.loads((src / "config.json").read_text())
tc = dict(cfg["text_config"])
tc["model_type"] = "lfm2"
tc["architectures"] = ["Lfm2ForCausalLM"]
tc["tie_word_embeddings"] = True
# mlx-swift-lm 3.32.3 の LFM2Configuration は intermediate_size を読まず block_ff_dim を要求する
tc["block_ff_dim"] = tc["intermediate_size"]
(dst / "config.json").write_text(json.dumps(tc, indent=2))

for name in ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "LICENSE"):
    if (src / name).exists():
        shutil.copyfile(src / name, dst / name)
(dst / "NOTICE-MODIFIED.txt").write_text(
    "Derived from LiquidAI/d1-3B @ 051bcc464b01b9f92942b364d9586b0ef5912432: language model weights only "
    "(vision tower and projector removed), tensors renamed model.language_model.* -> model.*.\n")
print("wrote", dst)
