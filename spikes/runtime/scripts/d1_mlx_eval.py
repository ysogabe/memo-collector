"""MLX (Python) で d1-3B 言語モデルを動かし、PyTorch 参照と数値一致・精度・レイテンシ・メモリを比べる。

usage: spikes/runtime/.venv/bin/python -I spikes/runtime/scripts/d1_mlx_eval.py <reference.json> <model_dir> <out.json>

参照 JSON の token ids をそのまま入れる（トークナイザ差を排除）。最終位置 logits を readout_ids で
max-pool → softmax（d1 の prompt.readout と同じ）。キャッシュなし・1 質問 1 forward（chain 経路）。
"""

from __future__ import annotations

import json
import math
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import mlx.core as mx
import psutil
from mlx_lm import load

ref = json.loads(Path(sys.argv[1]).read_text())
model_dir, out_path = sys.argv[2], Path(sys.argv[3])

t0 = time.perf_counter()
model, _tok = load(model_dir)
mx.eval(model.parameters())
load_s = time.perf_counter() - t0
mem_after_load = mx.get_active_memory() / 1e6


def last_logits(ids: list[int]) -> mx.array:
    x = mx.array([ids])
    lg = model(x)[0, -1].astype(mx.float32)
    mx.eval(lg)
    return lg


def readout(lg, groups):
    s = [max(float(lg[i]) for i in g) for g in groups]
    m = max(s)
    e = [math.exp(v - m) for v in s]
    return [v / sum(e) for v in e]


def readout_from_dict(d, groups):
    s = [max(d[str(i)] for i in g) for g in groups]
    m = max(s)
    e = [math.exp(v - m) for v in s]
    return [v / sum(e) for v in e]


rows = []
for r in ref["rows"]:
    o = {"id": r["id"], "split": r["split"], "gold_intent": r["gold_intent"], "gold_deadline": r["gold_deadline"]}
    for name in ("intent", "deadline"):
        q = r["q"][name]
        lg = last_logits(q["ids"])
        o[name] = {"probs": readout(lg, q["groups"]), "chain_probs": q["chain_probs"], "tree_probs": q["tree_probs"],
                   "logit_diffs": [float(lg[int(i)]) - v for i, v in q["chain_logits"].items()]}
    rows.append(o)

labels = ref["rows"][0]["labels"]


def argmax(p):
    return max(range(len(p)), key=p.__getitem__)


def summarize(sel):
    s = {}
    for name in ("intent", "deadline"):
        for refk in ("chain_probs", "tree_probs"):
            diffs = [max(abs(a - b) for a, b in zip(x[name]["probs"], x[name][refk])) for x in sel]
            top1 = sum(argmax(x[name]["probs"]) == argmax(x[name][refk]) for x in sel)
            s[f"{name}_vs_{refk}"] = {"max_abs_dp": round(max(diffs), 5), "mean_max_abs_dp": round(statistics.mean(diffs), 5),
                                      "top1_agree": f"{top1}/{len(sel)}"}
        ld = [abs(d) for x in sel for d in x[name]["logit_diffs"]]
        s[f"{name}_option_logit_abs_diff_max"] = round(max(ld), 4)
    acc = sum(labels[argmax(x["intent"]["probs"])] == x["gold_intent"] for x in sel)
    acc_ref = sum(labels[argmax(x["intent"]["tree_probs"])] == x["gold_intent"] for x in sel)
    acc_chain = sum(labels[argmax(x["intent"]["chain_probs"])] == x["gold_intent"] for x in sel)
    s["intent_accuracy"] = f"{acc}/{len(sel)}"
    s["intent_accuracy_torch_tree"] = f"{acc_ref}/{len(sel)}"
    s["intent_accuracy_torch_chain"] = f"{acc_chain}/{len(sel)}"
    dl = [x for x in sel if x["gold_deadline"] is not None]
    if dl:
        s["deadline_accuracy@0.5"] = f"{sum((x['deadline']['probs'][0] >= 0.5) == x['gold_deadline'] for x in dl)}/{len(dl)}"
        s["deadline_accuracy@0.5_torch_tree"] = f"{sum((x['deadline']['tree_probs'][0] >= 0.5) == x['gold_deadline'] for x in dl)}/{len(dl)}"
    return s


summary = {sp: summarize([x for x in rows if x["split"] == sp]) for sp in ("dev", "holdout")}
summary["all"] = summarize(rows)

# レイテンシ: 1 注釈あたり intent+deadline の 2 forward（chain）。3 周の中央値。
bench = {"started_at": datetime.now(timezone.utc).isoformat(), "reps": []}
for _ in range(3):
    lats = []
    for r in ref["rows"]:
        t = time.perf_counter()
        for name in ("intent", "deadline"):
            last_logits(r["q"][name]["ids"])
        lats.append(time.perf_counter() - t)
    bench["reps"].append({"median_s": round(statistics.median(lats), 4),
                          "p90_s": round(sorted(lats)[int(0.9 * (len(lats) - 1))], 4)})
bench["finished_at"] = datetime.now(timezone.utc).isoformat()
bench["median_of_medians_s"] = statistics.median(x["median_s"] for x in bench["reps"])

out = {"model_dir": model_dir, "mlx": mx.__version__, "load_s": round(load_s, 2),
       "active_mem_after_load_mb": round(mem_after_load, 1), "peak_mem_mb": round(mx.get_peak_memory() / 1e6, 1),
       "rss_mb": round(psutil.Process().memory_info().rss / 1e6, 1),
       "summary": summary, "bench": bench, "rows": rows}
out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps({k: out[k] for k in ("load_s", "active_mem_after_load_mb", "peak_mem_mb")}, indent=1))
print(json.dumps(summary, indent=1))
print(json.dumps(bench, indent=1))
