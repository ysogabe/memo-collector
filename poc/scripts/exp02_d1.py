"""EXP-02/03: d1 判定モデル（d1-omni-600M / d1-3B）の分類精度とレイテンシ。

usage: python exp02_d1.py omni|3b

タスク
- intent      : 注釈 → todo/research/code/note/schedule（＋期限言及の有無）
    条件: 正解テキスト(英語指示/日本語指示), STT テキスト, STT+スクショ+メタ, 音声直接(omni のみ)
- screen      : スクショ → 画面種別 / 秘密情報の写り込み（プライバシーガード）
    条件: 画像のみ, 画像+アプリ名/ウインドウタイトル/URL
"""

from __future__ import annotations

import json
import sys
import time

import soundfile as sf
import torch
from PIL import Image
from transformers import AutoModel

from common import (CONTEXT_Q, D1_3B, D1_OMNI, DEADLINE_Q, FIX, INTENT_Q_EN, INTENT_Q_JA, RESULTS, SECRET_Q,
                    accuracy, binary_metrics, env_info, free, lat_summary, load_dataset, meta_text, mps_mb, rss_mb,
                    save, screens_by_id, sync, timer)

# モデルカードの推奨 dtype は 2 モデルで逆なので共有しない
CONFIG = {
    "omni": {"repo": D1_OMNI, "dtype": torch.float16, "audio": True},  # bf16 は回答が変わるため非推奨
    "3b": {"repo": D1_3B, "dtype": torch.bfloat16, "audio": False},
}


def call(model, state, questions, **kw) -> tuple[dict, float]:
    sync()
    t = time.perf_counter()
    r = model.system_one(state, questions, **kw)
    sync()
    return r, time.perf_counter() - t


def main(which: str) -> None:
    cfg = CONFIG[which]
    repo, rev = cfg["repo"]
    ds = load_dataset()
    screens = screens_by_id(ds)
    stt_path = RESULTS / "exp01_stt.json"
    stt = {}
    if stt_path.exists():
        stt = {r["id"]: r["hyp"] for r in json.loads(stt_path.read_text())["vocab_prompt"]["rows"]}

    out: dict = {"env": env_info(), "model": repo, "revision": rev, "dtype": str(cfg["dtype"])}
    rss0 = rss_mb()
    load: dict = {}
    with timer(load, "load_s"):
        model = AutoModel.from_pretrained(repo, revision=rev, trust_remote_code=True, dtype=cfg["dtype"]).to("mps")
        model.eval()
    out["load"] = {**load, "rss_delta_mb": round(rss_mb() - rss0, 1), **mps_mb()}

    imgs = {sid: Image.open(FIX / "screens" / f"{sid}.png").convert("RGB") for sid in screens}
    # ウォームアップ（初回のカーネルコンパイル分を計測から外す）
    _, out["first_text_call_s"] = call(model, "warm up", {"i": INTENT_Q_EN})
    _, out["first_image_call_s"] = call(model, None, {"c": CONTEXT_Q}, images=[imgs["s01"]])

    # ---- intent ----
    conditions = {
        "text_gold_en": lambda c: (c["text"], {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q}, {}),
        "text_gold_ja": lambda c: (c["text"], {"intent": INTENT_Q_JA, "deadline": DEADLINE_Q}, {}),
    }
    if stt:
        conditions["text_stt_en"] = lambda c: (stt[c["id"]], {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q}, {})
        conditions["stt_plus_screen_en"] = lambda c: (
            f"{meta_text(screens[c['screen']])}\nVoice note: {stt[c['id']]}",
            {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q},
            {"images": [imgs[c["screen"]]]},
        )
    if cfg["audio"]:
        def audio_cond(c):
            a, sr = sf.read(FIX / "audio" / f"c{c['id']:02d}.wav", dtype="int16")
            assert sr == 16000
            return "Voice note spoken by the user while looking at their screen.", \
                {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q}, {"audio": a}
        conditions["audio_direct_en"] = audio_cond

    out["intent"] = {}
    for name, build in conditions.items():
        rows, pairs, dl_pairs, lats = [], [], [], []
        for c in ds["captures"]:
            state, qs, kw = build(c)
            r, dt = call(model, state, qs, **kw)
            a = r["answers"]
            pred = a["intent"]["choice"]
            pairs.append((c["intent"], pred))
            dl_pairs.append((c["has_deadline"], a["deadline"]["noul"]))
            lats.append(dt)
            rows.append({"id": c["id"], "gold": c["intent"], "pred": pred,
                         "confidence": round(a["intent"]["confidence"], 3),
                         "deadline_gold": c["has_deadline"], "deadline_p": round(a["deadline"]["noul"], 3),
                         "input_tokens": r["usage"]["input_tokens"], "latency_s": round(dt, 4)})
        acc = accuracy(pairs)
        # 低確信度を「未分類のまま Inbox に残す」運用を想定した選択的精度
        sel = {}
        for th in (0.5, 0.7):
            kept = [x for x in rows if x["confidence"] >= th]
            sel[str(th)] = {"coverage": round(len(kept) / len(rows), 3),
                            "accuracy": round(sum(x["gold"] == x["pred"] for x in kept) / len(kept), 3) if kept else None}
        out["intent"][name] = {"accuracy": acc["accuracy"], "correct": acc["correct"], "n": acc["n"],
                               "selective": sel, "deadline": binary_metrics(dl_pairs),
                               "latency": lat_summary(lats), "confusion": acc["confusion"], "rows": rows}
        print(which, name, acc["accuracy"], out["intent"][name]["deadline"]["accuracy"], lat_summary(lats)["p50_s"])

    # ---- screen ----
    out["screen"] = {}
    for name, state_fn in {"img_only": lambda s: None, "img_plus_meta": meta_text}.items():
        rows, ctx_pairs, sec_pairs, lats = [], [], [], []
        for sid, s in screens.items():
            r, dt = call(model, state_fn(s), {"context": CONTEXT_Q, "secret": SECRET_Q}, images=[imgs[sid]])
            a = r["answers"]
            ctx_pairs.append((s["context_type"], a["context"]["choice"]))
            sec_pairs.append((s["contains_secret"], a["secret"]["noul"]))
            lats.append(dt)
            rows.append({"id": sid, "context_gold": s["context_type"], "context_pred": a["context"]["choice"],
                         "secret_gold": s["contains_secret"], "secret_p": round(a["secret"]["noul"], 3),
                         "input_tokens": r["usage"]["input_tokens"], "latency_s": round(dt, 4)})
        acc = accuracy(ctx_pairs)
        out["screen"][name] = {"context_accuracy": acc["accuracy"], "context_confusion": acc["confusion"],
                               "secret@0.5": binary_metrics(sec_pairs, 0.5),
                               "secret@0.3": binary_metrics(sec_pairs, 0.3),
                               "latency": lat_summary(lats), "rows": rows}
        print(which, name, acc["accuracy"], out["screen"][name]["secret@0.5"])

    # ---- batch throughput（バックグラウンド整理での一括処理を想定）----
    batch = [(c["text"], {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q}) for c in ds["captures"]]
    sync()
    t = time.perf_counter()
    model.system_one_batch(batch)
    sync()
    out["batch_text_30_s"] = round(time.perf_counter() - t, 3)

    out["peak"] = {"rss_mb": round(rss_mb(), 1), **mps_mb()}
    save(f"exp02_d1_{which}", out)
    del model
    free()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "omni")
