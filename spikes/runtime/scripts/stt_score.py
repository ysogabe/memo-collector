"""stt-swift の出力 JSON を poc/scripts/common.py の cer() で採点する（正規化を PoC と同一にするため）。

usage: poc/.venv/bin/python -I spikes/runtime/scripts/stt_score.py <repo_root> <stt_out.json> [...]
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / "poc" / "scripts"))
from common import cer, lat_summary, load_dataset  # noqa: E402

refs = {c["id"]: c["text"] for c in load_dataset()["captures"]}
for p in sys.argv[2:]:
    d = json.loads(Path(p).read_text())
    cers = [cer(refs[r["id"]], r["hyp"]) for r in d["rows"]]
    lat = lat_summary([r["latency_s_median3"] for r in d["rows"]])
    d["score"] = {"mean_cer": round(statistics.mean(cers), 4), "median_cer": round(statistics.median(cers), 4),
                  "max_cer": round(max(cers), 4), "latency": lat}
    for r, c in zip(d["rows"], cers):
        r["cer"] = round(c, 4)
    Path(p).write_text(json.dumps(d, ensure_ascii=False, indent=1))
    print(Path(p).name, d["meta"].get("variant"), "prompt" if d["meta"].get("prompt") else "", d["score"]["mean_cer"],
          "p50", lat["p50_s"], "p90", lat["p90_s"], "load", round(d["load_s"], 1), "rss", round(d["rss_mb_after"]))
