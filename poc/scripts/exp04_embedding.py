"""EXP-04: EmbeddingGemma 2 による Context Inbox 検索。

- text   : 日本語クエリ → キャプチャ（注釈 + アプリ/ウインドウ/URL）
- image  : 日本語クエリ → スクリーンショット単体（クロスモーダル）
- fused  : 日本語クエリ → 注釈テキスト + スクショを 1 ベクトルにした interleaved 埋め込み
- audio  : 日本語クエリ → 音声メモ単体（STT を経ない検索が成立するか）
次元 768 / 256 を比較（MRL）。dtype は bf16（f16 は非推奨）。
"""

from __future__ import annotations

import time

import numpy as np
import soundfile as sf
import torch
from sentence_transformers import SentenceTransformer

from common import EMBED, FIX, env_info, lat_summary, load_dataset, meta_text, mps_mb, rss_mb, save, screens_by_id, sync


def recall_mrr(sim: np.ndarray, doc_ids: list, queries: list[dict], k: int = 3) -> dict:
    hits, rr, rows = [], [], []
    for qi, q in enumerate(queries):
        order = [doc_ids[i] for i in np.argsort(-sim[qi])]
        rel = set(q["relevant"])
        topk = order[:k]
        hits.append(len(rel & set(topk)) / min(k, len(rel)))
        first = next((r for r, d in enumerate(order, 1) if d in rel), None)
        rr.append(1 / first if first else 0)
        rows.append({"q": q["q"], "relevant": q["relevant"], "top5": order[:5]})
    return {f"recall@{k}": round(float(np.mean(hits)), 3), "mrr": round(float(np.mean(rr)), 3), "rows": rows}


def main() -> None:
    ds = load_dataset()
    screens = screens_by_id(ds)
    out: dict = {"env": env_info(), "model": EMBED}
    rss0 = rss_mb()
    t = time.perf_counter()
    model = SentenceTransformer(EMBED, device="mps", model_kwargs={"torch_dtype": torch.bfloat16})
    sync()
    out["load"] = {"load_s": round(time.perf_counter() - t, 3), "rss_delta_mb": round(rss_mb() - rss0, 1), **mps_mb()}

    def enc(x, **kw):
        sync()
        t0 = time.perf_counter()
        e = model.encode(x, normalize_embeddings=True, convert_to_numpy=True, **kw)
        sync()
        return e, time.perf_counter() - t0

    enc("warm up", prompt_name="SearchQuery")
    caps = ds["captures"]
    cap_ids = [c["id"] for c in caps]
    scr_ids = list(screens)

    doc_texts = [f"title: {screens[c['screen']]['window_title']} | text: {c['text']}\n{meta_text(screens[c['screen']])}"
                 for c in caps]

    # 1 件ずつのエンコード遅延（キャプチャ保存時にインデックスする想定）
    lat = {"text_doc": [], "image": [], "audio": [], "fused": [], "query": []}
    text_docs, img_docs, audio_docs, fused_docs = [], [], [], []
    for d in doc_texts:
        e, dt = enc(d)
        text_docs.append(e)
        lat["text_doc"].append(dt)
    for sid in scr_ids:
        e, dt = enc({"image": str(FIX / "screens" / f"{sid}.png")})
        img_docs.append(e)
        lat["image"].append(dt)
    for c in caps:
        a, sr = sf.read(FIX / "audio" / f"c{c['id']:02d}.wav", dtype="float32")
        e, dt = enc({"audio": a})
        audio_docs.append(e)
        lat["audio"].append(dt)
        e, dt = enc({"text": f"title: {screens[c['screen']]['window_title']} | text: {c['text']} <|image|>",
                     "image": [str(FIX / "screens" / f"{c['screen']}.png")]})
        fused_docs.append(e)
        lat["fused"].append(dt)

    tq = [q["q"] for q in ds["text_queries"]]
    iq = [q["q"] for q in ds["image_queries"]]
    tq_emb = np.stack([enc(q, prompt_name="SearchQuery")[0] for q in tq])
    iq_emb = []
    for q in iq:
        e, dt = enc(q, prompt_name="SearchQuery")
        iq_emb.append(e)
        lat["query"].append(dt)
    iq_emb = np.stack(iq_emb)
    out["latency"] = {k: lat_summary(v) for k, v in lat.items()}

    def trunc(m: np.ndarray, d: int) -> np.ndarray:
        m = m[..., :d]
        return m / np.linalg.norm(m, axis=-1, keepdims=True)

    T, I, A, F = map(np.stack, (text_docs, img_docs, audio_docs, fused_docs))
    out["retrieval"] = {}
    for dim in (768, 256):
        r = {}
        r["text→capture(text+meta)"] = recall_mrr(trunc(tq_emb, dim) @ trunc(T, dim).T, cap_ids, ds["text_queries"])
        r["text→capture(fused text+image)"] = recall_mrr(trunc(tq_emb, dim) @ trunc(F, dim).T, cap_ids, ds["text_queries"])
        r["text→capture(audio only)"] = recall_mrr(trunc(tq_emb, dim) @ trunc(A, dim).T, cap_ids, ds["text_queries"])
        r["text→screenshot(image only)"] = recall_mrr(trunc(iq_emb, dim) @ trunc(I, dim).T, scr_ids, ds["image_queries"])
        out["retrieval"][str(dim)] = r
        for k, v in r.items():
            print(dim, k, v["recall@3"], v["mrr"])

    # 重複検知の素材: 同じ画面に付いた注釈同士の類似度 vs 別画面
    S = T @ T.T
    same, diff = [], []
    for i, a in enumerate(caps):
        for j, b in enumerate(caps):
            if i < j:
                (same if a["screen"] == b["screen"] else diff).append(float(S[i, j]))
    out["similarity_same_screen_vs_other"] = {"same_mean": round(float(np.mean(same)), 3),
                                              "other_mean": round(float(np.mean(diff)), 3)}
    out["peak"] = {"rss_mb": round(rss_mb(), 1), **mps_mb()}
    save("exp04_embedding", out)


if __name__ == "__main__":
    main()
