"""FluidInference/embeddinggemma-2-coreml を coremltools で動かし、PyTorch 参照（spikes/runtime/data/embed_reference.npz）
とのコサイン・exp04 と同じ Recall@3/MRR・レイテンシ・ロード時間・メモリを測る。

入力は sentence-transformers の前処理結果（data/st_inputs.npz、dump_st_inputs.py が作る）をそのまま使う。
= トークナイザと画像前処理は参照と同一にし、Core ML の数値だけを切り出して比べる。

usage: .venv/bin/python -I scripts/coreml_eval.py <model_dir> <compiled_dir> <repo_root> <text_cu> <vision_cu> <out.json>
  *_cu: CPU_AND_NE | CPU_AND_GPU | ALL | CPU_ONLY
  compiled_dir: .mlmodelc を置く（無ければコンパイルして作る）
"""
from __future__ import annotations

import json
import resource
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import coremltools as ct
import numpy as np
import psutil

model_dir, comp_dir, root = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
text_cu, vision_cu, out_path = sys.argv[4], sys.argv[5], Path(sys.argv[6])
CU = {k: getattr(ct.ComputeUnit, k) for k in ("CPU_AND_NE", "CPU_AND_GPU", "ALL", "CPU_ONLY")}
proc = psutil.Process()
out = {"started_at": datetime.now(timezone.utc).isoformat(), "text_cu": text_cu, "vision_cu": vision_cu,
       "rss_start_mb": round(proc.memory_info().rss / 1e6, 1)}

ref = np.load(root / "spikes/runtime/data/embed_reference.npz")
meta = json.loads((root / "spikes/runtime/data/embed_reference.json").read_text())
ds = json.loads((root / "poc/fixtures/dataset.json").read_text())
st = np.load(root / "spikes/fluid/data/st_inputs.npz")
cfg = json.loads((model_dir / "config.json").read_text())

H, SCALE = 512, np.float32(cfg["embed_scale"])
LENGTHS = [32, 48, 64, 128, 256, 512]
table = np.memmap(model_dir / "embeddings.bf16", dtype=np.uint16, mode="r").reshape(-1, H)
pos_table = np.fromfile(model_dir / "position_embeddings.f16", dtype=np.float16).reshape(2, 1024, 768).astype(np.float32)
SOFT = 258880  # <|image|> ソフトトークン（HF プロセッサが 273 個などに展開したもの）


def rows(ids):
    return (table[np.asarray(ids)].astype(np.uint32) << 16).view(np.float32) * SCALE


def compiled(pkg: str) -> Path:
    dst = comp_dir / f"{pkg}.mlmodelc"
    if not dst.exists():
        comp_dir.mkdir(parents=True, exist_ok=True)
        t = time.perf_counter()
        tmp = ct.utils.compile_model(str(model_dir / f"{pkg}.mlpackage"))
        Path(tmp).rename(dst)
        out[f"compile_{pkg}_s"] = round(time.perf_counter() - t, 2)
    return dst


# ---- ロード（関数ごとに 1 インスタンス。初回は ANE/GPU 向けの device コンパイルを含む）
t0 = time.perf_counter()
tpath = compiled("EmbeddingGemma2Text")
text_models = {L: ct.models.CompiledMLModel(str(tpath), compute_units=CU[text_cu], function_name=f"embed_{L}") for L in LENGTHS}
out["load_text_s"] = round(time.perf_counter() - t0, 2)
t1 = time.perf_counter()
vpath = compiled("EmbeddingGemma2Vision")
vision = ct.models.CompiledMLModel(str(vpath), compute_units=CU[vision_cu], function_name="vision_280")
out["load_vision_s"] = round(time.perf_counter() - t1, 2)
out["rss_after_load_mb"] = round(proc.memory_info().rss / 1e6, 1)


def run_text(embeds: np.ndarray) -> np.ndarray:
    n = embeds.shape[0]
    L = next(x for x in LENGTHS if x >= n)
    x = np.zeros((1, L, H), np.float16)
    x[0, :n] = embeds
    m = np.zeros((1, L), np.float16)
    m[0, :n] = 1
    v = text_models[L].predict({"inputs_embeds": x, "attention_mask": m})["embedding"].astype(np.float32)[0]
    return v / np.linalg.norm(v)


def embed_ids(ids) -> np.ndarray:
    return run_text(rows(ids))


def vision_tokens(key: str) -> np.ndarray:
    pv = st[f"{key}__pixel_values"][0]            # [2520, 768] in [0,1]
    pos = st[f"{key}__image_position_ids"][0]     # [2520, 2] (x, y), padding -1
    N, T = 2520, 280
    valid = pos[:, 0] >= 0
    pe = np.zeros((N, 768), np.float32)
    pe[valid] = pos_table[0][pos[valid, 0]] + pos_table[1][pos[valid, 1]]
    gw = (pos[valid, 0].max() + 1) // 3
    pool = np.zeros((T, N), np.float32)
    idx = np.nonzero(valid)[0]
    tok = (pos[idx, 1] // 3) * gw + (pos[idx, 0] // 3)  # 3x3 グループを行優先で並べる
    pool[tok, idx] = 1 / 9
    n_tok = int(valid.sum() // 9)
    o = vision.predict({"patches": pv[None].astype(np.float16), "positions": pos[None].astype(np.float16),
                        "pool": pool.astype(np.float16), "valid": valid[None].astype(np.float16),
                        "position_embeddings": pe[None].astype(np.float16)})["image_tokens"]
    return o[0, :n_tok].astype(np.float32)


def embed_with_image(key: str) -> np.ndarray:
    ids = st[f"{key}__input_ids"][0]
    e = rows(ids)
    vt = vision_tokens(key)
    slots = np.nonzero(ids == SOFT)[0]
    assert len(slots) == len(vt), (key, len(slots), len(vt))
    e[slots] = vt
    return run_text(e)


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


# ---- 初回推論（ANE は初回 predict にも準備が乗るので分けて記録）
t = time.perf_counter()
embed_ids(st["tq0__input_ids"][0])
out["first_text_predict_s"] = round(time.perf_counter() - t, 3)
t = time.perf_counter()
embed_with_image("img0")
out["first_image_predict_s"] = round(time.perf_counter() - t, 3)

keys = {"text_docs": [f"doc{i}" for i in range(len(meta["doc_texts"]))],
        "text_queries": [f"tq{i}" for i in range(len(meta["text_queries"]))],
        "image_queries": [f"iq{i}" for i in range(len(meta["image_queries"]))]}
E = {k: np.stack([embed_ids(st[f"{x}__input_ids"][0]) for x in v]) for k, v in keys.items()}
E["images"] = np.stack([embed_with_image(f"img{i}") for i in range(len(meta["scr_ids"]))])
E["fused"] = np.stack([embed_with_image(f"fu{i}") for i in range(len(meta["fused_texts"]))])
out["token_lengths"] = {k: [int(st[f"{x}__input_ids"].shape[1]) for x in v] for k, v in keys.items()}

cos = lambda a, b: (a * b).sum(-1) / np.linalg.norm(a, axis=-1) / np.linalg.norm(b, axis=-1)  # noqa: E731
out["cos_vs_torch"] = {k: {"min": round(float(cos(v, ref[k]).min()), 5), "mean": round(float(cos(v, ref[k]).mean()), 5)}
                       for k, v in E.items()}
cap_ids, scr_ids = meta["cap_ids"], meta["scr_ids"]
out["retrieval"] = {}
for dim in (768, 256):
    r = {}
    for name, src in (("coreml", E), ("torch_ref", ref)):
        r[f"{name} text→capture(text+meta)"] = recall_mrr(trunc(src["text_queries"], dim) @ trunc(src["text_docs"], dim).T, cap_ids, ds["text_queries"])
        r[f"{name} text→capture(fused)"] = recall_mrr(trunc(src["text_queries"], dim) @ trunc(src["fused"], dim).T, cap_ids, ds["text_queries"])
        r[f"{name} image_query→screenshot"] = recall_mrr(trunc(src["image_queries"], dim) @ trunc(src["images"], dim).T, scr_ids, ds["image_queries"])
    out["retrieval"][str(dim)] = r

# ---- レイテンシ（3 周、各周の中央値 → その中央値）
bench = {"started_at": datetime.now(timezone.utc).isoformat()}
cases = (("text_doc", lambda k: embed_ids(st[f"{k}__input_ids"][0]), keys["text_docs"]),
         ("query", lambda k: embed_ids(st[f"{k}__input_ids"][0]), keys["text_queries"]),
         ("vision_only", vision_tokens, [f"img{i}" for i in range(len(scr_ids))]),
         ("image_embed", embed_with_image, [f"img{i}" for i in range(len(scr_ids))]),
         ("fused_embed", embed_with_image, [f"fu{i}" for i in range(len(meta['fused_texts']))]))
for name, fn, items in cases:
    reps = []
    for _ in range(3):
        lats = []
        for k in items:
            t = time.perf_counter()
            fn(k)
            lats.append(time.perf_counter() - t)
        reps.append(statistics.median(lats))
    bench[name] = {"median_s_each_rep": [round(x, 4) for x in reps], "median_s": round(statistics.median(reps), 4)}
bench["finished_at"] = datetime.now(timezone.utc).isoformat()
out["bench"] = bench
out["rss_end_mb"] = round(proc.memory_info().rss / 1e6, 1)
out["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 1)  # macOS は bytes
try:
    out["phys_footprint_mb"] = round(proc.memory_full_info().uss / 1e6, 1)
except Exception:  # noqa: BLE001
    pass
np.savez(out_path.with_suffix(".npz"), **E)
out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps(out, ensure_ascii=False, indent=1))
