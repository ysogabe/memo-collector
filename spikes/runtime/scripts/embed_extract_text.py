"""EmbeddingGemma 2 のテキスト塔（language_model.*）だけを抜き出す（重みの値は無変更）。
usage: .venv-embed/bin/python -I scripts/embed_extract_text.py <snapshot_dir> <out_dir>"""
import shutil, sys
from pathlib import Path
import mlx.core as mx
src, dst = Path(sys.argv[1]), Path(sys.argv[2]); dst.mkdir(parents=True, exist_ok=True)
w = mx.load(str(src / "model.safetensors"))
mx.save_safetensors(str(dst / "model.safetensors"), {k: v for k, v in w.items() if k.startswith("language_model.")})
for f in ("tokenizer.json", "tokenizer_config.json", "config.json"):
    shutil.copyfile(src / f, dst / f)
print("wrote", dst)
