"""d1-3B の PyTorch 参照値を作る（poc/.venv で参照実行のみ）。

usage: poc/.venv/bin/python -I spikes/runtime/scripts/d1_reference.py <repo_root> <out.json> [mps|cpu32]

各注釈（dev 30 + holdout 22）× 質問（INTENT_Q_EN, DEADLINE_Q）について
- prompt 文字列・token ids（d1 の render そのまま。BOS は文字列に含まれる）
- readout_ids（選択肢ごとのトークン ID 群。max-pool → softmax）
- chain 経路: 1 質問 1 forward の最終位置 logits（readout_ids 分）と確率
- tree 経路: system_one(text, {intent, deadline})（PoC と同じ呼び方）の確率
を保存する。レイテンシは各経路を 3 周して中央値。
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

import torch  # noqa: E402
from transformers import AutoModel  # noqa: E402

from common import D1_3B, DEADLINE_Q, FIX, INTENT_Q_EN, mps_mb, rss_mb, sync  # noqa: E402

out_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else "mps"
device, dtype = ("mps", torch.bfloat16) if mode == "mps" else ("cpu", torch.float32)

ds = json.loads((FIX / "dataset.json").read_text(encoding="utf-8"))
ho = json.loads((FIX / "holdout.json").read_text(encoding="utf-8"))
items = [{"split": "dev", **c} for c in ds["captures"]] + [{"split": "holdout", **c} for c in ho["captures"]]

repo, rev = D1_3B
t0 = time.perf_counter()
model = AutoModel.from_pretrained(repo, revision=rev, trust_remote_code=True, dtype=dtype).to(device).eval()
load_s = time.perf_counter() - t0
eng = model.engine
tok = eng.tokenizer

# runner/prompt モジュールは remote code 側にある
prompt_mod = sys.modules[type(eng).__module__.replace("runner", "prompt")]
QS = {"intent": prompt_mod.as_question(INTENT_Q_EN), "deadline": prompt_mod.as_question(DEADLINE_Q)}


def tsync():
    if device == "mps":
        sync()


@torch.inference_mode()
def chain_logits(ids: list[int]) -> torch.Tensor:
    x = torch.tensor([ids], device=device)
    return model(input_ids=x, logits_to_keep=1).logits[0, -1].float()


rows = []
for it in items:
    row = {"id": it["id"], "split": it["split"], "text": it["text"], "gold_intent": it["intent"],
           "gold_deadline": it.get("has_deadline"), "q": {}}
    for name, q in QS.items():
        prompt = eng.render(it["text"], q)
        ids = tok.encode(prompt, add_special_tokens=False)
        groups = prompt_mod.readout_ids(tok, q)
        lg = chain_logits(ids)
        logz = lg - torch.logsumexp(lg, -1)
        probs = prompt_mod.readout(tok, q, logz)
        row["q"][name] = {"prompt": prompt, "ids": ids, "groups": groups,
                          "chain_logits": {str(i): float(lg[i]) for g in groups for i in g},
                          "chain_probs": probs}
    r = model.system_one(it["text"], {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q})
    a = r["answers"]
    row["q"]["intent"]["tree_probs"] = list(a["intent"]["probabilities"].values())
    row["q"]["deadline"]["tree_probs"] = [a["deadline"]["noul"], 1 - a["deadline"]["noul"]]
    row["labels"] = list(INTENT_Q_EN["criteria"].keys())
    rows.append(row)
    print(it["id"], a["intent"]["choice"], flush=True)


def bench(fn, reps=3):
    per = []
    for _ in range(reps):
        lats = []
        for it in items:
            tsync()
            t = time.perf_counter()
            fn(it)
            tsync()
            lats.append(time.perf_counter() - t)
        per.append(statistics.median(lats))
    return {"median_per_item_s_each_rep": [round(x, 4) for x in per], "median_s": round(statistics.median(per), 4)}


bench_out = {"started_at": datetime.now(timezone.utc).isoformat()}
bench_out["tree_2q"] = bench(lambda it: model.system_one(it["text"], {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q}))
bench_out["chain_intent_only"] = bench(lambda it: model.system_one(it["text"], {"intent": INTENT_Q_EN}))
bench_out["finished_at"] = datetime.now(timezone.utc).isoformat()

out = {"mode": mode, "dtype": str(dtype), "device": device, "revision": rev, "torch": torch.__version__,
       "load_s": round(load_s, 2), "rss_mb": round(rss_mb(), 1), **(mps_mb() if device == "mps" else {}),
       "bench": bench_out, "rows": rows}
out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
print("saved", out_path)
