"""5 チャンクを順に通す 1 件分の所要時間（チャンク別）。
usage: .venv-coreml/bin/python -I scripts/d1_coreml_pipeline_probe.py <coreml_dir> <compute_unit> <T>"""
import sys, time
import numpy as np
import coremltools as ct
d, cu, T = sys.argv[1], sys.argv[2], int(sys.argv[3])
ms = []
for c in range(5):
    t = time.perf_counter()
    ms.append(ct.models.MLModel(f"{d}/chunk{c}.mlpackage", compute_units=getattr(ct.ComputeUnit, cu)))
    print("load", c, round(time.perf_counter() - t, 2), flush=True)
for rep in range(3):
    x = {"input_ids": np.random.randint(0, 120000, (1, T)).astype(np.int32)}
    for c, m in enumerate(ms):
        t = time.perf_counter()
        o = m.predict(x)["out"]
        print("rep", rep, "chunk", c, o.shape, o.dtype, round(time.perf_counter() - t, 3), flush=True)
        x = {"hidden_in": o.astype(np.float16)}
