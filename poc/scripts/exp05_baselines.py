"""EXP-05: d1 と比べるためのベースライン。

- intent_rules      : 日本語キーワードのルールベース（会話で提案された「最初は LLM すら不要」案）
- intent_embed_zs   : EmbeddingGemma 2 のラベル説明文との類似度（ゼロショット）
- intent_embed_knn  : EmbeddingGemma 2 の leave-one-out kNN（ユーザーが過去に付けた分類から学ぶ想定）
- secret_ocr_regex  : Apple Vision OCR + 正規表現（API キー / トークン / パスワード表示）
"""

from __future__ import annotations

import json
import re
import subprocess
import time

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

from common import EMBED, FIX, INTENT_Q_JA, INTENTS, RESULTS, ROOT, accuracy, binary_metrics, lat_summary, \
    load_dataset, save

RULES = [  # 上から順に評価
    ("schedule", r"(\d+時|午前|午後).*(打ち合わせ|会議|定例|歯医者|予約|$)|定例は|打ち合わせ$|会議$|歯医者"),
    ("code", r"(実装し|直して|直しておいて|修正して|リファクタ|テストを書|Claude ?Code|やらせて)"),
    ("research", r"(調べて|調べておいて|サーベイ|比較して|調査)"),
    ("todo", r"(する$|します$|返す$|読む$|確認する$|注文|あとで|後で|更新|変更しておく|までに)"),
]
SECRET_PATTERNS = {
    "openai_key": r"sk-(proj-)?[A-Za-z0-9_-]{20,}",
    "anthropic_key": r"sk-ant-[A-Za-z0-9_-]{20,}",
    "stripe_key": r"sk_(live|test)_[A-Za-z0-9]{16,}",
    "aws_access_key": r"AKIA[0-9A-Z]{16}",
    "aws_secret_label": r"(?i)secret access key",
    "github_token": r"gh[pousr]_[A-Za-z0-9]{30,}",
    "password_field": r"(?i)(password|パスワード)\s*[:=（(]",
    "dsn_password": r"://[^:\s]+:[^@\s]+@",
}


def rule_intent(text: str) -> str:
    for label, pat in RULES:
        if re.search(pat, text):
            return label
    return "note"


def main() -> None:
    ds = load_dataset()
    caps = ds["captures"]
    stt = {r["id"]: r["hyp"] for r in json.loads((RESULTS / "exp01_stt.json").read_text())["vocab_prompt"]["rows"]}
    out: dict = {}

    for src_name, get in {"gold": lambda c: c["text"], "stt": lambda c: stt[c["id"]]}.items():
        pairs = [(c["intent"], rule_intent(get(c))) for c in caps]
        a = accuracy(pairs)
        out[f"intent_rules_{src_name}"] = {"accuracy": a["accuracy"], "confusion": a["confusion"]}
        print("rules", src_name, a["accuracy"])

    model = SentenceTransformer(EMBED, device="mps", model_kwargs={"torch_dtype": torch.bfloat16},
                                config_kwargs={"vision_config": None, "audio_config": None})
    texts = [c["text"] for c in caps]
    E = model.encode(texts, prompt_name="Classification", normalize_embeddings=True)
    L = model.encode([INTENT_Q_JA["criteria"][k] for k in INTENTS], prompt_name="Classification",
                     normalize_embeddings=True)
    zs = [INTENTS[i] for i in np.argmax(E @ L.T, axis=1)]
    a = accuracy([(c["intent"], p) for c, p in zip(caps, zs)])
    out["intent_embed_zeroshot"] = {"accuracy": a["accuracy"], "confusion": a["confusion"]}
    print("embed zs", a["accuracy"])

    S = E @ E.T
    np.fill_diagonal(S, -1)
    for k in (1, 3):
        preds = []
        for i in range(len(caps)):
            nn = np.argsort(-S[i])[:k]
            votes = [caps[j]["intent"] for j in nn]
            preds.append(max(set(votes), key=lambda v: (votes.count(v), -votes.index(v))))
        a = accuracy([(c["intent"], p) for c, p in zip(caps, preds)])
        out[f"intent_embed_knn{k}_loo"] = {"accuracy": a["accuracy"], "confusion": a["confusion"]}
        print("embed knn", k, a["accuracy"])

    # ---- OCR + regex ----
    pngs = sorted((FIX / "screens").glob("*.png"))
    t = time.perf_counter()
    proc = subprocess.run(["swift", str(ROOT / "scripts" / "ocr.swift"), *map(str, pngs)],
                          capture_output=True, text=True, check=True)
    wall = time.perf_counter() - t
    screens = {s["id"]: s for s in ds["screens"]}
    rows, pairs, lats = [], [], []
    for line in proc.stdout.splitlines():
        o = json.loads(line)
        sid = o["path"].rsplit("/", 1)[-1].removesuffix(".png")
        hits = [name for name, pat in SECRET_PATTERNS.items() if re.search(pat, o["text"])]
        pairs.append((screens[sid]["contains_secret"], 1.0 if hits else 0.0))
        lats.append(o["ms"] / 1000)
        rows.append({"id": sid, "gold": screens[sid]["contains_secret"], "hits": hits, "ocr_ms": o["ms"],
                     "ocr_chars": len(o["text"])})
        print("ocr", sid, screens[sid]["contains_secret"], hits, o["ms"])
    out["secret_ocr_regex"] = {"metrics": binary_metrics(pairs), "ocr_latency": lat_summary(lats),
                               "swift_wall_incl_compile_s": round(wall, 2), "rows": rows}
    save("exp05_baselines", out)


if __name__ == "__main__":
    main()
