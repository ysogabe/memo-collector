"""EmbeddingGemma 2 を MLX (mlx-vlm main) で動かし、PyTorch 参照とのコサイン類似度・exp04 と同じ Recall@3/MRR・
レイテンシ・メモリを測る。

usage: .venv-embed/bin/python -I scripts/embed_mlx_eval.py <embeddinggemma2_snapshot_dir> <embed_reference.npz> <dataset.json> <out.json> [q8]
"""

from __future__ import annotations

import json
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx_vlm.embedding_loader import load_embedding_model
from transformers import AutoProcessor, AutoTokenizer

snap, ref_npz, ds_path, out_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
quant = sys.argv[5] if len(sys.argv) > 5 else None
ref = np.load(ref_npz)
meta = json.loads(ref_npz.with_suffix(".json").read_text())
ds = json.loads(ds_path.read_text())

t0 = time.perf_counter()
model = load_embedding_model(snap)
if quant == "q8":
    nn.quantize(model.language_model, group_size=64, bits=8)
mx.eval(model.parameters())
load_s = time.perf_counter() - t0
mem_load = mx.get_active_memory() / 1e6
tok = AutoTokenizer.from_pretrained(snap)


def embed_text(s: str) -> np.ndarray:
    ids = tok(s, return_tensors="np")
    o = model(input_ids=mx.array(ids["input_ids"]), attention_mask=mx.array(ids["attention_mask"])).text_embeds
    mx.eval(o)
    return np.array(o.astype(mx.float32))[0]


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


embed_text("warm up")
T = np.stack([embed_text(s) for s in meta["doc_texts"]])
TQ = np.stack([embed_text(s) for s in meta["text_queries"]])
IQ = np.stack([embed_text(s) for s in meta["image_queries"]])

out = {"quant": quant, "load_s": round(load_s, 2), "active_mem_after_load_mb": round(mem_load, 1)}
cos = lambda a, b: (a * b).sum(-1) / np.linalg.norm(a, axis=-1) / np.linalg.norm(b, axis=-1)  # noqa: E731
out["cos_vs_torch"] = {k: {"min": float(cos(v, ref[k]).min()), "mean": float(cos(v, ref[k]).mean())}
                       for k, v in (("text_docs", T), ("text_queries", TQ), ("image_queries", IQ))}

# 画像（できれば）: mlx-vlm のプロセッサで画像 1 枚 → 埋め込み
img_status = "not attempted"
I = None
FU = None
try:
    proc = AutoProcessor.from_pretrained(snap)
    from PIL import Image

    fix = ds_path.parent
    embs = []
    img_lat = []
    for sid in meta["scr_ids"]:
        im = Image.open(fix / "screens" / f"{sid}.png").convert("RGB")
        t = time.perf_counter()
        # sentence-transformers と同じ経路: processor にメッセージ形式で画像だけを渡す
        inp = proc(text=[proc.image_token if hasattr(proc, "image_token") else "<|image|>"], images=[[im]], return_tensors="np")
        kw = {k: mx.array(v) for k, v in inp.items() if hasattr(v, "shape")}
        o = model(**kw).text_embeds
        mx.eval(o)
        img_lat.append(time.perf_counter() - t)
        embs.append(np.array(o.astype(mx.float32))[0])
    I = np.stack(embs)
    fembs, flat = [], []
    for txt, scr in zip(meta["fused_texts"], meta["cap_screens"]):
        im = Image.open(fix / "screens" / f"{scr}.png").convert("RGB")
        t = time.perf_counter()
        inp = proc(text=[txt], images=[[im]], return_tensors="np")
        o = model(**{k: mx.array(v) for k, v in inp.items() if hasattr(v, "shape")}).text_embeds
        mx.eval(o)
        flat.append(time.perf_counter() - t)
        fembs.append(np.array(o.astype(mx.float32))[0])
    FU = np.stack(fembs)
    out["cos_vs_torch"]["fused"] = {"min": float(cos(FU, ref["fused"]).min()), "mean": float(cos(FU, ref["fused"]).mean())}
    out["fused_latency_p50_s"] = round(statistics.median(flat), 4)
    out["cos_vs_torch"]["images"] = {"min": float(cos(I, ref["images"]).min()), "mean": float(cos(I, ref["images"]).mean())}
    out["image_latency_p50_s"] = round(statistics.median(img_lat), 4)
    img_status = "ok"
except Exception as e:  # noqa: BLE001
    img_status = f"failed: {type(e).__name__}: {e}"[:400]
out["image_status"] = img_status

cap_ids = meta["cap_ids"]
out["retrieval"] = {}
for dim in (768, 256):
    r = {"text→capture(text+meta)": recall_mrr(trunc(TQ, dim) @ trunc(T, dim).T, cap_ids, ds["text_queries"]),
         "torch_ref text→capture(text+meta)": recall_mrr(trunc(ref["text_queries"], dim) @ trunc(ref["text_docs"], dim).T, cap_ids, ds["text_queries"])}
    if I is not None:
        r["text→screenshot(image only)"] = recall_mrr(trunc(IQ, dim) @ trunc(I, dim).T, meta["scr_ids"], ds["image_queries"])
        r["torch_ref text→screenshot(image only)"] = recall_mrr(trunc(ref["image_queries"], dim) @ trunc(ref["images"], dim).T, meta["scr_ids"], ds["image_queries"])
    if FU is not None:
        r["text→capture(fused text+image)"] = recall_mrr(trunc(TQ, dim) @ trunc(FU, dim).T, cap_ids, ds["text_queries"])
        r["torch_ref text→capture(fused text+image)"] = recall_mrr(trunc(ref["text_queries"], dim) @ trunc(ref["fused"], dim).T, cap_ids, ds["text_queries"])
    out["retrieval"][str(dim)] = r

bench = {"started_at": datetime.now(timezone.utc).isoformat()}
for name, items in (("text_doc", meta["doc_texts"]), ("query", meta["text_queries"])):
    reps = []
    for _ in range(3):
        lats = []
        for s in items:
            t = time.perf_counter()
            embed_text(s)
            lats.append(time.perf_counter() - t)
        reps.append(statistics.median(lats))
    bench[name] = {"median_s_each_rep": [round(x, 4) for x in reps], "median_s": round(statistics.median(reps), 4)}
bench["finished_at"] = datetime.now(timezone.utc).isoformat()
out["bench"] = bench
out["peak_mem_mb"] = round(mx.get_peak_memory() / 1e6, 1)
out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps(out, ensure_ascii=False, indent=1))
