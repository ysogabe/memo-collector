"""EXP-01: 日本語 STT（mlx-whisper large-v3-turbo / Metal GPU）。

d1 系は出力トークン 0 の判定モデルで文字起こしができないため、STT は別系統が必須。
ここでの transcript を後続実験（STT 経由の意図分類）が使う。
"""

from __future__ import annotations

import time

import mlx_whisper
import numpy as np
import soundfile as sf

from common import FIX, WHISPER, cer, env_info, lat_summary, load_dataset, rss_mb, save

INITIAL_PROMPT = "Hermes、Claude Code、OpenDots、GitHub、issue、pytest、adapter.ts"


def transcribe(audio: np.ndarray, prompt: str | None) -> dict:
    return mlx_whisper.transcribe(audio, path_or_hf_repo=WHISPER, language="ja", initial_prompt=prompt,
                                  condition_on_previous_text=False, verbose=None)


def main() -> None:
    ds = load_dataset()
    out: dict = {"env": env_info(), "model": WHISPER, "rows": []}
    warm = sf.read(FIX / "audio" / "c01.wav", dtype="float32")[0]
    t = time.perf_counter()
    transcribe(warm, None)
    out["cold_first_call_s"] = round(time.perf_counter() - t, 3)

    for variant, prompt in [("plain", None), ("vocab_prompt", INITIAL_PROMPT)]:
        rows, lats, cers = [], [], []
        for c in ds["captures"]:
            audio, sr = sf.read(FIX / "audio" / f"c{c['id']:02d}.wav", dtype="float32")
            assert sr == 16000
            t = time.perf_counter()
            text = transcribe(audio, prompt)["text"].strip()
            dt = time.perf_counter() - t
            e = cer(c["text"], text)
            rows.append({"id": c["id"], "ref": c["text"], "hyp": text, "cer": round(e, 3), "latency_s": round(dt, 3),
                         "audio_s": round(len(audio) / sr, 2)})
            lats.append(dt)
            cers.append(e)
            print(variant, c["id"], round(dt, 2), round(e, 3), text)
        out[variant] = {"latency": lat_summary(lats), "mean_cer": round(float(np.mean(cers)), 4),
                        "exact_after_norm": sum(1 for r in rows if r["cer"] == 0), "rows": rows}
    out["rss_mb"] = round(rss_mb(), 1)
    save("exp01_stt", out)


if __name__ == "__main__":
    main()
