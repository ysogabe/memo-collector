"""chunk0（埋め込み gather + 6 層）の読み込みと初回推論の所要時間。
usage: .venv-coreml/bin/python -I scripts/d1_coreml_chunk0_probe.py <coreml_dir> <compute_unit>"""
import sys, time
import numpy as np
import coremltools as ct
d, cu = sys.argv[1], sys.argv[2]
t = time.perf_counter()
m = ct.models.MLModel(f"{d}/chunk0.mlpackage", compute_units=getattr(ct.ComputeUnit, cu))
print("load", round(time.perf_counter() - t, 2), flush=True)
for T in (150, 150, 60):
    t = time.perf_counter(); m.predict({"input_ids": np.random.randint(0, 120000, (1, T)).astype(np.int32)})
    print(T, round(time.perf_counter() - t, 3), flush=True)
