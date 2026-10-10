"""embed-swift の出力で exp04 と同じ Recall@3 / MRR（text→capture(text+meta)）を出す。
usage: python3 scripts/embed_swift_score.py <embed_text_ids.json> <embed_swift_out.json> <dataset.json>"""
import json, sys
import numpy as np
items = json.load(open(sys.argv[1]))["items"]; out = json.load(open(sys.argv[2])); ds = json.load(open(sys.argv[3]))
E = np.array(out["embeddings"], dtype=np.float32)
kinds = [it["kind"] for it in items]
T = E[[i for i, k in enumerate(kinds) if k == "doc"]]; TQ = E[[i for i, k in enumerate(kinds) if k == "text_query"]]
R = np.array([it["ref"] for it in items], dtype=np.float32)
RT = R[[i for i, k in enumerate(kinds) if k == "doc"]]; RQ = R[[i for i, k in enumerate(kinds) if k == "text_query"]]
cap_ids = [c["id"] for c in ds["captures"]]
def recall_mrr(sim, queries, k=3):  # poc/scripts/exp04_embedding.py と同一
    hits, rr = [], []
    for qi, q in enumerate(queries):
        order = [cap_ids[i] for i in np.argsort(-sim[qi])]
        rel = set(q["relevant"]); hits.append(len(rel & set(order[:k])) / min(k, len(rel)))
        first = next((r for r, d in enumerate(order, 1) if d in rel), None); rr.append(1 / first if first else 0)
    return round(float(np.mean(hits)), 3), round(float(np.mean(rr)), 3)
tr = lambda m, d: m[:, :d] / np.linalg.norm(m[:, :d], axis=1, keepdims=True)
for d in (768, 256):
    print(d, "swift", recall_mrr(tr(TQ, d) @ tr(T, d).T, ds["text_queries"]), "torch", recall_mrr(tr(RQ, d) @ tr(RT, d).T, ds["text_queries"]))
