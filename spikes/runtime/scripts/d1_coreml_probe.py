"""Core ML 変換の時間制限つき検証（d1-3B 言語モデル）。

usage:
  .venv-coreml/bin/python -I scripts/d1_coreml_probe.py slice  <text_model_dir> <out_dir>
  .venv-coreml/bin/python -I scripts/d1_coreml_probe.py full   <text_model_dir> <out_dir> [chunks=3]
  .venv-coreml/bin/python -I scripts/d1_coreml_probe.py eval   <text_model_dir> <out_dir> <reference.json> <result.json> [compute_units]

方針
- d1 は出力トークン 0（1 回の prefill の最終位置だけ読む）なので KV キャッシュ・ステートフルモデルは不要。
- hybrid.py の tree=None 経路と同じ計算を、Core ML が素直に下ろせる演算（matmul + 明示 causal mask、
  depthwise conv1d、half-split RoPE）で書き直した最小 torch 実装を変換する。
- lm_head（128000×2048）は変換しない。readout が使う選択肢トークン（≤12 個）の埋め込み行との内積だけで
  確率が決まるため、モデル出力は最終位置の hidden（2048）にする。
- 系列長は RangeDim(1..512)。精度 fp16（Core ML の GPU/ANE 既定）。
"""

from __future__ import annotations

import json
import math
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors import safe_open

torch.set_grad_enabled(False)


class RMSNorm(nn.Module):
    def __init__(self, w, eps):
        super().__init__()
        self.weight = nn.Parameter(w, requires_grad=False)
        self.eps = eps

    def forward(self, x):
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps) * self.weight


def rope_tables(T, dim, theta):
    inv = 1.0 / theta ** (torch.arange(0, dim, 2).float() / dim)
    ang = torch.arange(T).float()[:, None] * inv
    ang = torch.cat((ang, ang), -1)
    return ang.cos(), ang.sin()


class Layer(nn.Module):
    def __init__(self, kind, W, p, cfg):
        super().__init__()
        self.kind = kind
        eps = cfg["norm_eps"]
        g = lambda k: W[p + k]  # noqa: E731
        self.operator_norm = RMSNorm(g("operator_norm.weight"), eps)
        self.ffn_norm = RMSNorm(g("ffn_norm.weight"), eps)
        lin = lambda w: nn.Parameter(w, requires_grad=False)  # noqa: E731
        self.w1, self.w2, self.w3 = (lin(g(f"feed_forward.{n}.weight")) for n in ("w1", "w2", "w3"))
        if kind == "conv":
            self.in_proj = lin(g("conv.in_proj.weight"))
            self.out_proj = lin(g("conv.out_proj.weight"))
            cw = g("conv.conv.weight")  # HF: (C, 1, K)
            self.conv_w = lin(cw)
            self.C, self.K = int(cw.shape[0]), int(cw.shape[-1])  # python int（trace で aten::Int を作らない）
        else:
            self.H, self.KV, self.D = cfg["num_attention_heads"], cfg["num_key_value_heads"], cfg["hidden_size"] // cfg["num_attention_heads"]
            self.q = lin(g("self_attn.q_proj.weight"))
            self.k = lin(g("self_attn.k_proj.weight"))
            self.v = lin(g("self_attn.v_proj.weight"))
            self.o = lin(g("self_attn.out_proj.weight"))
            self.qn = RMSNorm(g("self_attn.q_layernorm.weight"), eps)
            self.kn = RMSNorm(g("self_attn.k_layernorm.weight"), eps)
            self.theta = cfg["rope_parameters"]["rope_theta"] if cfg.get("rope_parameters") else 1e6

    def op(self, x, cos, sin, mask):
        if self.kind == "conv":
            b, c, u = F.linear(x, self.in_proj).chunk(3, dim=-1)
            bu = (b * u).transpose(1, 2)  # (1, C, T)
            z = F.conv1d(F.pad(bu, (self.K - 1, 0)), self.conv_w, groups=self.C)
            return F.linear(c * z.transpose(1, 2), self.out_proj)
        q = self.qn(F.linear(x, self.q).view(1, -1, self.H, self.D)).transpose(1, 2)
        k = self.kn(F.linear(x, self.k).view(1, -1, self.KV, self.D)).transpose(1, 2)
        v = F.linear(x, self.v).view(1, -1, self.KV, self.D).transpose(1, 2)

        def rot(t):
            a, b2 = t.chunk(2, dim=-1)
            return t * cos + torch.cat((-b2, a), -1) * sin
        q, k = rot(q), rot(k)
        rep = self.H // self.KV
        k = k[:, :, None].expand(-1, -1, rep, -1, -1).reshape(1, self.H, -1, self.D)
        v = v[:, :, None].expand(-1, -1, rep, -1, -1).reshape(1, self.H, -1, self.D)
        s = (q @ k.transpose(-1, -2)) * (self.D ** -0.5) + mask
        y = torch.softmax(s, -1) @ v
        return F.linear(y.transpose(1, 2).reshape(1, -1, self.H * self.D), self.o)

    def forward(self, x, cos, sin, mask):
        h = x + self.op(self.operator_norm(x), cos, sin, mask)
        f = self.ffn_norm(h)
        return h + F.linear(F.silu(F.linear(f, self.w1)) * F.linear(f, self.w3), self.w2)


class Chunk(nn.Module):
    """layers[lo:hi]。first なら input_ids を受けて埋め込み、last なら最終 norm 後の最終位置 hidden を返す。"""

    def __init__(self, W, cfg, lo, hi, first, last, all_positions=False):
        super().__init__()
        self.first, self.last, self.all_positions = first, last, all_positions
        if first:
            self.embed = nn.Parameter(W["model.embed_tokens.weight"], requires_grad=False)
        self.layers = nn.ModuleList(Layer(cfg["layer_types"][i], W, f"model.layers.{i}.", cfg) for i in range(lo, hi))
        if last:
            self.norm = RMSNorm(W["model.embedding_norm.weight"], cfg["norm_eps"])
        self.D = cfg["hidden_size"] // cfg["num_attention_heads"]
        self.theta = cfg["rope_parameters"]["rope_theta"]

    def forward(self, x):
        if self.first:
            x = F.embedding(x, self.embed)
        # torch.arange(T) は trace で aten::Int を生み coremltools が落ちるので、cumsum で位置を作る
        pos = torch.cumsum(torch.ones_like(x[0, :, 0]), 0) - 1
        inv = 1.0 / self.theta ** (torch.arange(0, self.D, 2, dtype=torch.float32) / self.D)
        ang = pos[:, None] * inv[None, :]
        ang = torch.cat((ang, ang), -1)
        cos, sin = ang.cos(), ang.sin()
        mask = torch.where(pos[None, :] <= pos[:, None], 0.0, -1e4)
        for layer in self.layers:
            x = layer(x, cos, sin, mask)
        if self.last:
            return self.norm(x) if self.all_positions else self.norm(x)[:, -1, :]
        return x


def load_weights(model_dir: Path, keep=None) -> tuple[dict, dict]:
    cfg = json.loads((model_dir / "config.json").read_text())
    W = {}
    with safe_open(str(model_dir / "model.safetensors"), "pt") as f:
        for k in f.keys():
            if keep is None or keep(k):
                W[k] = f.get_tensor(k).float()
    return W, cfg


def convert(chunk: nn.Module, first: bool, path: Path, T: int = 32):
    import coremltools as ct

    chunk.eval()
    ex = torch.randint(0, 1000, (1, T)) if first else torch.randn(1, T, 2048) * 0.1
    traced = torch.jit.trace(chunk, ex, check_trace=False)
    seq = ct.RangeDim(lower_bound=1, upper_bound=512, default=T)
    inp = (ct.TensorType(name="input_ids", shape=(1, seq), dtype=np.int32) if first
           else ct.TensorType(name="hidden_in", shape=(1, seq, 2048), dtype=np.float16))
    t = time.perf_counter()
    m = ct.convert(traced, inputs=[inp], outputs=[ct.TensorType(name="out", dtype=np.float16)],
                   minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16,
                   convert_to="mlprogram")
    m.save(str(path))
    return time.perf_counter() - t


def main():
    mode, model_dir, out_dir = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    import coremltools as ct

    if mode == "slice":
        W, cfg = load_weights(model_dir)
        ch = Chunk(W, cfg, 0, 3, first=True, last=True)  # conv, conv, full_attention
        dt = convert(ch, True, out_dir / "slice3.mlpackage")
        res = {"convert_s": round(dt, 1)}
        ml = ct.models.MLModel(str(out_dir / "slice3.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_GPU)
        for T in (17, 150):
            ids = torch.randint(0, 120000, (1, T))
            ref = ch(ids).numpy()[0]
            got = ml.predict({"input_ids": ids.numpy().astype(np.int32)})["out"].astype(np.float32)[0]
            cos = float(ref @ got / np.linalg.norm(ref) / np.linalg.norm(got))
            res[f"T{T}"] = {"cos": cos, "max_abs": float(np.abs(ref - got).max()), "ref_absmax": float(np.abs(ref).max())}
        print(json.dumps(res, indent=1))
        (out_dir / "slice_result.json").write_text(json.dumps(res, indent=1))
        return

    if mode == "full":
        nchunks = int(sys.argv[4]) if len(sys.argv) > 4 else 3
        W, cfg = load_weights(model_dir)
        L = cfg["num_hidden_layers"]
        bounds = [round(i * L / nchunks) for i in range(nchunks + 1)]
        info = {"bounds": bounds, "convert_s": []}
        for c in range(nchunks):
            ch = Chunk(W, cfg, bounds[c], bounds[c + 1], first=c == 0, last=c == nchunks - 1)
            info["convert_s"].append(round(convert(ch, c == 0, out_dir / f"chunk{c}.mlpackage"), 1))
            del ch
            print("chunk", c, info["convert_s"][-1], flush=True)
        (out_dir / "chunks.json").write_text(json.dumps(info))
        return

    if mode == "last_all":
        # 最終チャンクだけ「全位置の hidden を返す」版で作り直す（右パディング + 固定長バケット用）
        info = json.loads((out_dir / "chunks.json").read_text())
        lo, hi = info["bounds"][-2], info["bounds"][-1]
        W, cfg = load_weights(model_dir, keep=lambda k: k == "model.embedding_norm.weight" or any(
            k.startswith(f"model.layers.{i}.") for i in range(lo, hi)))
        ch = Chunk(W, cfg, lo, hi, first=False, last=True, all_positions=True)
        print("convert_s", convert(ch, False, out_dir / f"chunk{len(info['bounds']) - 2}_all.mlpackage"))
        return

    if mode == "eval":
        ref = json.loads(Path(sys.argv[4]).read_text())
        result_path = Path(sys.argv[5])
        cu = getattr(ct.ComputeUnit, sys.argv[6] if len(sys.argv) > 6 else "CPU_AND_GPU")
        info = json.loads((out_dir / "chunks.json").read_text())
        t = time.perf_counter()
        nch = len(info["bounds"]) - 1
        # 可変長のまま流すと系列長ごとに MPSGraph の特殊化が走り、時間とメモリが膨らむ（実測でスワップ 15GB）。
        # 64 / 160 の 2 バケットへ右パディングし、最終チャンクは全位置版から実長-1 の位置を読む。
        models = [ct.models.MLModel(str(out_dir / (f"chunk{c}_all.mlpackage" if c == nch - 1 else f"chunk{c}.mlpackage")),
                                    compute_units=cu) for c in range(nch)]
        BUCKETS = (64, 160)
        PAD = 124893
        load_s = time.perf_counter() - t
        with safe_open(str(model_dir / "model.safetensors"), "pt") as f:
            E = f.get_tensor("model.embed_tokens.weight").float().numpy()

        def hidden(ids):
            n = next(b for b in BUCKETS if b >= len(ids))
            x = {"input_ids": np.array([ids + [PAD] * (n - len(ids))], dtype=np.int32)}
            for i, m in enumerate(models):
                o = m.predict(x)["out"]
                x = {"hidden_in": o.astype(np.float16)}
            return o.astype(np.float32)[0, len(ids) - 1]

        def readout(h, groups):
            s = [max(float(E[i] @ h) for i in g) for g in groups]
            mx_ = max(s)
            e = [math.exp(v - mx_) for v in s]
            return [v / sum(e) for v in e]

        rows = []
        for k, r in enumerate(ref["rows"]):
            print("row", k, flush=True)
            o = {"id": r["id"], "split": r["split"], "gold": r["gold_intent"]}
            for name in ("intent", "deadline"):
                q = r["q"][name]
                o[name] = {"probs": readout(hidden(q["ids"]), q["groups"]), "chain": q["chain_probs"], "tree": q["tree_probs"]}
            rows.append(o)
        am = lambda p: max(range(len(p)), key=p.__getitem__)  # noqa: E731
        labels = ref["rows"][0]["labels"]
        summ = {}
        for sp in ("dev", "holdout", "all"):
            sel = [x for x in rows if sp == "all" or x["split"] == sp]
            s = {}
            for name in ("intent", "deadline"):
                for rk in ("chain", "tree"):
                    s[f"{name}_vs_{rk}"] = {"max_abs_dp": max(max(abs(a - b) for a, b in zip(x[name]["probs"], x[name][rk])) for x in sel),
                                            "top1_agree": f"{sum(am(x[name]['probs']) == am(x[name][rk]) for x in sel)}/{len(sel)}"}
            s["intent_accuracy"] = f"{sum(labels[am(x['intent']['probs'])] == x['gold'] for x in sel)}/{len(sel)}"
            summ[sp] = s
        result_path.write_text(json.dumps({"compute_units": str(cu), "load_s": round(load_s, 1), "summary": summ,
                                           "rows": rows, "bench": "pending"}, indent=1))
        print(json.dumps(summ, indent=1), flush=True)
        # 共有マシンでの GPU メモリ逼迫を避けるため、ベンチは先頭 20 件 × 3 周に絞る
        bench = {"started_at": datetime.now(timezone.utc).isoformat(), "reps": [], "n_items": 20}
        for _ in range(3):
            lats = []
            for r in ref["rows"][:20]:
                t = time.perf_counter()
                for name in ("intent", "deadline"):
                    hidden(r["q"][name]["ids"])
                lats.append(time.perf_counter() - t)
            bench["reps"].append(round(statistics.median(lats), 4))
        bench["finished_at"] = datetime.now(timezone.utc).isoformat()
        out = {"compute_units": str(cu), "load_s": round(load_s, 1), "summary": summ, "bench": bench, "rows": rows}
        result_path.write_text(json.dumps(out, indent=1))
        print(json.dumps({"load_s": out["load_s"], "summary": summ, "bench": bench}, indent=1))


if __name__ == "__main__":
    main()
