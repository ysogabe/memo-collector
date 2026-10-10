"""EXP-06: ホールドアウト評価 + 全モデル同時ロード時の E2E 計測 + d1-3B の画像解像度と速度。

1. holdout     : 未見 22 件で rules / d1-omni / d1-3B の意図分類を比較（rules の過適合を測る）
2. e2e         : whisper + d1-3B + EmbeddingGemma 2 を同時常駐させたときのメモリと、
                 キャプチャ経路（STT → 意図 → テキスト埋め込み）／後段（OCR → d1-3B 画像 → 融合埋め込み）の所要時間
3. resolution  : d1-3B の画像入力を 1440 / 1024 / 720 px 幅に縮小したときの精度と遅延
"""

from __future__ import annotations

import json
import subprocess
import time

import mlx_whisper
import numpy as np
import soundfile as sf
import torch
from PIL import Image
from sentence_transformers import SentenceTransformer
from transformers import AutoModel

from common import (CONTEXT_Q, D1_3B, D1_OMNI, DEADLINE_Q, EMBED, FIX, INTENT_Q_EN, ROOT, SECRET_Q, WHISPER,
                    accuracy, binary_metrics, env_info, free, lat_summary, load_dataset, meta_text, mps_mb, rss_mb,
                    save, screens_by_id, sync)
from exp05_baselines import SECRET_PATTERNS, rule_intent


def timed(fn, *a, **kw):
    sync()
    t = time.perf_counter()
    r = fn(*a, **kw)
    sync()
    return r, time.perf_counter() - t


def d1_intent(model, caps) -> dict:
    pairs, lats, rows = [], [], []
    for c in caps:
        r, dt = timed(model.system_one, c["text"], {"intent": INTENT_Q_EN})
        p = r["answers"]["intent"]["choice"]
        pairs.append((c["intent"], p))
        lats.append(dt)
        rows.append({"id": c["id"], "gold": c["intent"], "pred": p,
                     "confidence": round(r["answers"]["intent"]["confidence"], 3)})
    a = accuracy(pairs)
    return {"accuracy": a["accuracy"], "confusion": a["confusion"], "latency": lat_summary(lats), "rows": rows}


def main() -> None:
    ds = load_dataset()
    holdout = json.loads((FIX / "holdout.json").read_text(encoding="utf-8"))["captures"]
    screens = screens_by_id(ds)
    out: dict = {"env": env_info()}

    # ---- 1. holdout ----
    h: dict = {}
    pairs = [(c["intent"], rule_intent(c["text"])) for c in holdout]
    a = accuracy(pairs)
    h["rules"] = {"accuracy": a["accuracy"], "confusion": a["confusion"],
                  "rows": [{"id": c["id"], "gold": g, "pred": p} for c, (g, p) in zip(holdout, pairs)]}
    print("holdout rules", a["accuracy"])
    omni = AutoModel.from_pretrained(D1_OMNI[0], revision=D1_OMNI[1], trust_remote_code=True,
                                     dtype=torch.float16).to("mps")
    omni.system_one("warm", {"intent": INTENT_Q_EN})
    h["d1_omni"] = d1_intent(omni, holdout)
    print("holdout omni", h["d1_omni"]["accuracy"])
    del omni
    free()

    # ---- 2. 全モデル同時常駐 ----
    rss0 = rss_mb()
    load = {}
    t = time.perf_counter()
    d1 = AutoModel.from_pretrained(D1_3B[0], revision=D1_3B[1], trust_remote_code=True,
                                   dtype=torch.bfloat16).to("mps")
    sync()
    load["d1_3b_s"] = round(time.perf_counter() - t, 2)
    t = time.perf_counter()
    emb = SentenceTransformer(EMBED, device="mps", model_kwargs={"torch_dtype": torch.bfloat16})
    sync()
    load["embeddinggemma_s"] = round(time.perf_counter() - t, 2)
    warm_audio = sf.read(FIX / "audio" / "c01.wav", dtype="float32")[0]
    t = time.perf_counter()
    mlx_whisper.transcribe(warm_audio, path_or_hf_repo=WHISPER, language="ja")
    load["whisper_first_call_s"] = round(time.perf_counter() - t, 2)
    d1.system_one("warm", {"intent": INTENT_Q_EN})
    d1.system_one(None, {"c": CONTEXT_Q}, images=[Image.open(FIX / "screens" / "s01.png").convert("RGB")])
    emb.encode("warm", prompt_name="Document")
    out["resident"] = {"load": load, "rss_mb": round(rss_mb(), 1), "rss_delta_mb": round(rss_mb() - rss0, 1),
                       **mps_mb()}
    print("resident", out["resident"])

    h["d1_3b"] = d1_intent(d1, holdout)
    print("holdout 3b", h["d1_3b"]["accuracy"])
    out["holdout"] = h

    # キャプチャ経路: ホットキー解放 → 保存可能になるまで
    cap_rows = []
    for c in ds["captures"]:
        audio = sf.read(FIX / "audio" / f"c{c['id']:02d}.wav", dtype="float32")[0]
        r_stt, t_stt = timed(mlx_whisper.transcribe, audio, path_or_hf_repo=WHISPER, language="ja",
                             condition_on_previous_text=False)
        text = r_stt["text"].strip()
        r_int, t_int = timed(d1.system_one, text, {"intent": INTENT_Q_EN, "deadline": DEADLINE_Q})
        _, t_emb = timed(emb.encode, f"title: {screens[c['screen']]['window_title']} | text: {text}",
                         normalize_embeddings=True)
        cap_rows.append({"id": c["id"], "audio_s": round(len(audio) / 16000, 2), "stt_s": round(t_stt, 3),
                         "intent_s": round(t_int, 3), "embed_s": round(t_emb, 3),
                         "total_s": round(t_stt + t_int + t_emb, 3),
                         "intent_ok": r_int["answers"]["intent"]["choice"] == c["intent"]})
    out["capture_path"] = {k: lat_summary([r[k] for r in cap_rows]) for k in ("stt_s", "intent_s", "embed_s", "total_s")}
    out["capture_path"]["intent_accuracy"] = round(np.mean([r["intent_ok"] for r in cap_rows]), 3)
    out["capture_path"]["rows"] = cap_rows
    print("capture path", out["capture_path"]["total_s"])

    # ---- 3. 解像度 vs d1-3B ----
    res: dict = {}
    for width in (1440, 1024, 720):
        rows, ctx, sec, lats = [], [], [], []
        for sid, s in screens.items():
            img = Image.open(FIX / "screens" / f"{sid}.png").convert("RGB")
            if width != img.width:
                img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
            r, dt = timed(d1.system_one, meta_text(s), {"context": CONTEXT_Q, "secret": SECRET_Q}, images=[img])
            a = r["answers"]
            ctx.append((s["context_type"], a["context"]["choice"]))
            sec.append((s["contains_secret"], a["secret"]["noul"]))
            lats.append(dt)
            rows.append({"id": sid, "context_pred": a["context"]["choice"], "secret_p": round(a["secret"]["noul"], 3),
                         "input_tokens": r["usage"]["input_tokens"]})
        res[str(width)] = {"context_accuracy": accuracy(ctx)["accuracy"], "secret@0.5": binary_metrics(sec, 0.5),
                           "secret@0.4": binary_metrics(sec, 0.4), "latency": lat_summary(lats),
                           "input_tokens": rows[0]["input_tokens"], "rows": rows}
        print("res", width, res[str(width)]["context_accuracy"], res[str(width)]["latency"]["p50_s"])
    out["d1_3b_resolution"] = res

    # 後段トリアージ（1 キャプチャあたり）: OCR+regex → d1-3B(1024px) → 融合埋め込み
    pngs = [str(FIX / "screens" / f"{sid}.png") for sid in screens]
    proc = subprocess.run(["swift", str(ROOT / "scripts" / "ocr.swift"), *pngs], capture_output=True, text=True,
                          check=True)
    ocr_ms = [json.loads(line)["ms"] / 1000 for line in proc.stdout.splitlines()][1:]  # 先頭はモデル初期化込み
    fused = []
    for c in ds["captures"][:14]:
        _, dt = timed(emb.encode, {"text": f"text: {c['text']} <|image|>",
                                   "image": [str(FIX / "screens" / f"{c['screen']}.png")]}, normalize_embeddings=True)
        fused.append(dt)
    out["background_triage"] = {"ocr_s": lat_summary(ocr_ms), "d1_3b_image_1024_s": res["1024"]["latency"],
                                "fused_embed_s": lat_summary(fused),
                                "secret_patterns": list(SECRET_PATTERNS)}
    out["peak"] = {"rss_mb": round(rss_mb(), 1), **mps_mb()}
    save("exp06_holdout_e2e", out)


if __name__ == "__main__":
    main()
