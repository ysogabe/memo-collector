"""Swift の出力（eg2-bench / eg2-image の JSON）を PyTorch 参照と比べ、exp04 と同じ指標を出す。

usage: .venv/bin/python -I scripts/score_swift.py <repo_root> <eg2-bench.json> <eg2-image.json> [st_inputs.npz]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

root = Path(sys.argv[1])
ref = np.load(root / "spikes/runtime/data/embed_reference.npz")
meta = json.loads((root / "spikes/runtime/data/embed_reference.json").read_text())
ds = json.loads((root / "poc/fixtures/dataset.json").read_text())
tb = json.loads(Path(sys.argv[2]).read_text())
im = json.loads(Path(sys.argv[3]).read_text())

kinds = tb["kinds"]
V = np.array(tb["vectors"], dtype=np.float32)
E = {"text_docs": V[[i for i, k in enumerate(kinds) if k.startswith("doc")]],
     "text_queries": V[[i for i, k in enumerate(kinds) if k.startswith("text_query")]],
     "image_queries": V[[i for i, k in enumerate(kinds) if k.startswith("image_query")]],
     "images": np.array(im["images"], dtype=np.float32), "fused": np.array(im["fused"], dtype=np.float32)}


def recall_mrr(sim, doc_ids, queries, k=3):  # poc/scripts/exp04_embedding.py と同一
    hits, rr = [], []
    for qi, q in enumerate(queries):
        order = [doc_ids[i] for i in np.argsort(-sim[qi])]
        rel = set(q["relevant"])
        hits.append(len(rel & set(order[:k])) / min(k, len(rel)))
        first = next((r for r, d in enumerate(order, 1) if d in rel), None)
        rr.append(1 / first if first else 0)
    return {f"recall@{k}": round(float(np.mean(hits)), 3), "mrr": round(float(np.mean(rr)), 3)}


def trunc(m, d):
    m = m[..., :d]
    return m / np.linalg.norm(m, axis=-1, keepdims=True)


cos = lambda a, b: (a * b).sum(-1) / np.linalg.norm(a, axis=-1) / np.linalg.norm(b, axis=-1)  # noqa: E731
out = {"cos_vs_torch": {k: {"min": round(float(cos(v, ref[k]).min()), 5), "mean": round(float(cos(v, ref[k]).mean()), 5)}
                        for k, v in E.items() if len(v)}}
if len(sys.argv) > 4:  # 融合入力の ids が HF と一致するか
    st = np.load(sys.argv[4])
    same = sum(st[f"fu{i}__input_ids"][0].tolist() == ids for i, ids in enumerate(im["fused_ids"]))
    out["fused_ids_match_hf"] = f"{same}/{len(im['fused_ids'])}"
    out["soft_tokens_match_hf"] = f"{sum(int((st[f'img{i}__input_ids'] == 258880).sum()) == n for i, n in enumerate(im['soft_tokens']))}/{len(im['soft_tokens'])}"
out["retrieval"] = {}
for dim in (768, 256):
    out["retrieval"][str(dim)] = {
        "text→capture(text+meta)": recall_mrr(trunc(E["text_queries"], dim) @ trunc(E["text_docs"], dim).T, meta["cap_ids"], ds["text_queries"]),
        "text→capture(fused)": recall_mrr(trunc(E["text_queries"], dim) @ trunc(E["fused"], dim).T, meta["cap_ids"], ds["text_queries"]),
        "image_query→screenshot": recall_mrr(trunc(E["image_queries"], dim) @ trunc(E["images"], dim).T, meta["scr_ids"], ds["image_queries"]),
    }
print(json.dumps(out, ensure_ascii=False, indent=1))
