"""Core ML chunk0 の可変長入力で、初回・同一長の再実行・別長の初回の所要時間を測る。
usage: .venv-coreml/bin/python -I scripts/d1_coreml_shape_probe.py <coreml_dir> <compute_unit> <out.json>"""
import json, sys, time
from datetime import datetime, timezone
import numpy as np
import coremltools as ct
d, cu, outp = sys.argv[1], sys.argv[2], sys.argv[3]
res = {"compute_units": cu, "started_at": datetime.now(timezone.utc).isoformat()}
t = time.perf_counter()
m = ct.models.MLModel(f"{d}/chunk1.mlpackage", compute_units=getattr(ct.ComputeUnit, cu))
res["load_s"] = round(time.perf_counter() - t, 2)
seq = []
for T in (150, 150, 150, 151, 151, 60, 60, 149):
    x = {"hidden_in": (np.random.randn(1, T, 2048) * 0.1).astype(np.float16)}
    t = time.perf_counter(); m.predict(x); dt = time.perf_counter() - t
    seq.append({"T": T, "s": round(dt, 3)}); print(T, round(dt, 3), flush=True)
res["calls_chunk1_6layers"] = seq
res["finished_at"] = datetime.now(timezone.utc).isoformat()
open(outp, "w").write(json.dumps(res, indent=1))
