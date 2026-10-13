"""results/coreml_*.json を 1 行ずつ要約する。usage: .venv/bin/python -I scripts/summarize.py results/coreml_*.json"""
import json
import sys

for p in sys.argv[1:]:
    d = json.loads(open(p).read())
    b = d["bench"]
    r = d["retrieval"]
    c = d["cos_vs_torch"]
    print(p.split("/")[-1], d["text_cu"], d["vision_cu"], "load", d["load_text_s"], d["load_vision_s"],
          "first", d["first_text_predict_s"], d["first_image_predict_s"],
          "| doc/q/vis/img/fu", *[b[k]["median_s"] for k in ("text_doc", "query", "vision_only", "image_embed", "fused_embed")],
          "| reps fu", b["fused_embed"]["median_s_each_rep"], b["started_at"][11:19],
          "| rss", d["rss_after_load_mb"], d["peak_rss_mb"], d.get("phys_footprint_mb"),
          "| cos min", {k: v["min"] for k, v in c.items()},
          "| fu256", r["256"]["coreml text→capture(fused)"], "img768", r["768"]["coreml image_query→screenshot"])
