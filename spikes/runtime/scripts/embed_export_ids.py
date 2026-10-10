"""Swift 検証用: 参照テキスト（doc/query）の HF トークン ID と PyTorch 参照埋め込みを JSON に書き出す。
usage: .venv-embed/bin/python -I scripts/embed_export_ids.py <snapshot_dir> <embed_reference.npz> <out.json>"""
import json, sys
from pathlib import Path
import numpy as np
from transformers import AutoTokenizer
snap, npz, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
ref = np.load(npz); meta = json.loads(npz.with_suffix(".json").read_text())
tok = AutoTokenizer.from_pretrained(snap)
items = []
for kind, texts, key in (("doc", meta["doc_texts"], "text_docs"), ("text_query", meta["text_queries"], "text_queries"),
                         ("image_query", meta["image_queries"], "image_queries")):
    for i, t in enumerate(texts):
        items.append({"kind": kind, "i": i, "text": t, "ids": tok(t)["input_ids"], "ref": ref[key][i].tolist()})
out.write_text(json.dumps({"items": items}, ensure_ascii=False))
print(len(items), "items; first ids", items[0]["ids"][:5])
