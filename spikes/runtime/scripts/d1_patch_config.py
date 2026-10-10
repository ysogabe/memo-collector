"""mlx_lm convert 後の config.json に block_ff_dim を追記する（mlx-swift-lm 3.32.3 の LFM2 が intermediate_size を読まないため）。
usage: python3 scripts/d1_patch_config.py <model_dir> [...]"""
import json, sys
for d in sys.argv[1:]:
    p = f"{d}/config.json"; c = json.load(open(p)); c["block_ff_dim"] = c["intermediate_size"]
    json.dump(c, open(p, "w"), indent=2); print("patched", p)
