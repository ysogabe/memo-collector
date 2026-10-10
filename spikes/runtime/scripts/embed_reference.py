"""EmbeddingGemma 2 の PyTorch 参照埋め込み（poc/.venv で参照実行のみ）。exp04 と同じ入力組み立て。

usage: poc/.venv/bin/python -I spikes/runtime/scripts/embed_reference.py <repo_root> <out.npz>

保存: text_docs(30) / text_queries / image_queries（SearchQuery プロンプト込み）/ images(14) の 768 次元 L2 正規化埋め込み、
およびそれぞれに入れた文字列（プロンプト適用後の生文字列）。
"""

from __future__ import annotations

import json
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / "poc" / "scripts"))

import numpy as np  # noqa: E402
import torch  # noqa: E402
from sentence_transformers import SentenceTransformer  # noqa: E402

from common import EMBED, FIX, load_dataset, meta_text, mps_mb, screens_by_id, sync  # noqa: E402

ds = load_dataset()
screens = screens_by_id(ds)
caps = ds["captures"]
model = SentenceTransformer(EMBED, device="mps", model_kwargs={"torch_dtype": torch.bfloat16})
prompt = model.prompts["SearchQuery"]

doc_texts = [f"title: {screens[c['screen']]['window_title']} | text: {c['text']}\n{meta_text(screens[c['screen']])}" for c in caps]
tq = [prompt + q["q"] for q in ds["text_queries"]]
iq = [prompt + q["q"] for q in ds["image_queries"]]
scr_ids = list(screens)


def enc(x):
    return model.encode(x, normalize_embeddings=True, convert_to_numpy=True)


enc("warm up")
T = np.stack([enc(d) for d in doc_texts])
TQ = np.stack([enc(q) for q in tq])
IQ = np.stack([enc(q) for q in iq])
I = np.stack([enc({"image": str(FIX / "screens" / f"{s}.png")}) for s in scr_ids])
# exp04 の fused（注釈テキスト + スクショを 1 ベクトル）。PRD §8.1 の検索インデックスはこの 256 次元
fused_texts = [f"title: {screens[c['screen']]['window_title']} | text: {c['text']} <|image|>" for c in caps]
FU = np.stack([enc({"text": t, "image": [str(FIX / "screens" / f"{c['screen']}.png")]}) for t, c in zip(fused_texts, caps)])

bench = {"started_at": datetime.now(timezone.utc).isoformat()}
for name, items in (("text_doc", doc_texts), ("query", tq)):
    reps = []
    for _ in range(3):
        lats = []
        for x in items:
            sync()
            t = time.perf_counter()
            enc(x)
            sync()
            lats.append(time.perf_counter() - t)
        reps.append(statistics.median(lats))
    bench[name] = {"median_s_each_rep": [round(r, 4) for r in reps], "median_s": round(statistics.median(reps), 4)}
bench["finished_at"] = datetime.now(timezone.utc).isoformat()
bench.update(mps_mb())

out = Path(sys.argv[2])
np.savez(out, text_docs=T, text_queries=TQ, image_queries=IQ, images=I, fused=FU)
out.with_suffix(".json").write_text(json.dumps({"doc_texts": doc_texts, "text_queries": tq, "image_queries": iq,
                                                "cap_ids": [c["id"] for c in caps], "scr_ids": scr_ids,
                                                "fused_texts": fused_texts, "cap_screens": [c["screen"] for c in caps],
                                                "bench": bench}, ensure_ascii=False, indent=1))
print(json.dumps(bench, indent=1))
