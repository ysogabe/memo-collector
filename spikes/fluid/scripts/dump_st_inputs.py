"""sentence-transformers が EmbeddingGemma 2 に渡す前処理済み入力（参照と同一経路）を npz に書き出す。
forward は行わない（CPU に読み込むだけ）。poc/.venv で参照実行する。

usage: poc/.venv/bin/python -I spikes/fluid/scripts/dump_st_inputs.py <repo_root> <out.npz>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
import numpy as np  # noqa: E402
from sentence_transformers import SentenceTransformer  # noqa: E402

meta = json.loads((root / "spikes/runtime/data/embed_reference.json").read_text())
fix = root / "poc/fixtures/screens"
model = SentenceTransformer("google/embeddinggemma-2", device="cpu")
out: dict[str, np.ndarray] = {}
info = {}


def dump(prefix, x):
    p = model.preprocess([x])
    keys = []
    for k, v in p.items():
        if hasattr(v, "numpy"):
            out[f"{prefix}__{k}"] = v.detach().cpu().float().numpy() if v.dtype.is_floating_point else v.detach().cpu().numpy()
            keys.append((k, list(v.shape), str(v.dtype)))
    return keys


for i, s in enumerate(meta["doc_texts"]):
    dump(f"doc{i}", s)
for i, s in enumerate(meta["text_queries"]):
    dump(f"tq{i}", s)
for i, s in enumerate(meta["image_queries"]):
    dump(f"iq{i}", s)
for i, sid in enumerate(meta["scr_ids"]):
    info[f"img{i}"] = dump(f"img{i}", {"image": str(fix / f"{sid}.png")})
for i, (t, sid) in enumerate(zip(meta["fused_texts"], meta["cap_screens"])):
    info[f"fu{i}"] = dump(f"fu{i}", {"text": t, "image": [str(fix / f"{sid}.png")]})
np.savez_compressed(sys.argv[2], **out)
print(json.dumps({k: info[k] for k in ("img0", "fu0")}, indent=1))
tok = model.tokenizer
print("img0 ids head/tail:", out["img0__input_ids"][0][:6].tolist(), out["img0__input_ids"][0][-4:].tolist(), out["img0__input_ids"].shape)
print("fu0 ids head/tail:", out["fu0__input_ids"][0][:6].tolist(), out["fu0__input_ids"][0][-4:].tolist())
