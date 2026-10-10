"""PoC 実験の共通処理: データセット読み込み・質問定義・計測ユーティリティ。"""

from __future__ import annotations

import gc
import json
import os
import platform
import re
import statistics
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path

import psutil

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "fixtures"
RESULTS = ROOT / "results"
RESULTS.mkdir(exist_ok=True)

# remote code を使うモデルは revision を固定する（trust_remote_code の対象を検証済みコミットに限定）
D1_OMNI = ("LiquidAI/d1-omni-600M", "02b55d7076f15129e59ab3f94783f32c4b088674")
D1_3B = ("LiquidAI/d1-3B", "051bcc464b01b9f92942b364d9586b0ef5912432")
EMBED = "google/embeddinggemma-2"
WHISPER = "mlx-community/whisper-large-v3-turbo"

INTENTS = ["todo", "research", "code", "note", "schedule"]
CONTEXT_TYPES = ["browser", "code", "terminal", "meeting", "document", "chat", "other"]

# d1 の質問定義。英語 instructions（モデルカードの学習分布に合わせる）と日本語版を比較する。
INTENT_Q_EN = {
    "type": "choice",
    "instructions": (
        "The user pressed a hotkey while looking at their screen and spoke this short voice note. "
        "What kind of follow-up does the note ask for?"
    ),
    "criteria": {
        "todo": "A personal to-do the user will do themselves (buy, reply, check, update, read)",
        "research": "Ask an AI agent to investigate, look up, survey or compare information",
        "code": "Ask a coding agent to write, fix, refactor or test source code",
        "note": "Just a remark or reference to remember; no action requested",
        "schedule": "An appointment or meeting at a specific date and time",
    },
}
INTENT_Q_JA = {
    "type": "choice",
    "instructions": "ユーザーが画面を見ながら話した短い音声メモです。このメモはどんな後続処理を求めていますか？",
    "criteria": {
        "todo": "ユーザー自身があとでやる作業（購入・返信・確認・更新・読む）",
        "research": "AIエージェントに調査・検索・比較・サーベイを任せる",
        "code": "コーディングエージェントにコードの実装・修正・リファクタ・テストを任せる",
        "note": "覚えておくための記録・感想・参照。行動は求めていない",
        "schedule": "特定の日時の予定・会議・アポイント",
    },
}
DEADLINE_Q = {
    "type": "noul",
    "instructions": "Does the note mention a date, day of the week or time (a deadline or an appointment)?",
}
CONTEXT_Q = {
    "type": "choice",
    "instructions": "What kind of window is shown in this screenshot?",
    "criteria": {
        "browser": "A web page in a web browser",
        "code": "Source code or config file in a code editor / IDE",
        "terminal": "A command-line terminal",
        "meeting": "A video call or online meeting",
        "document": "A document, PDF or note/wiki page",
        "chat": "A team chat or messaging app",
        "other": "Something else, e.g. a password manager or system settings",
    },
}
SECRET_Q = {
    "type": "noul",
    "instructions": (
        "Is a secret credential readable on screen, such as a password, API key, access token, "
        "private key or secret access key?"
    ),
}


def load_dataset() -> dict:
    return json.loads((FIX / "dataset.json").read_text(encoding="utf-8"))


def screens_by_id(ds: dict) -> dict:
    return {s["id"]: s for s in ds["screens"]}


def meta_text(screen: dict) -> str:
    parts = [f"App: {screen['app']}", f"Window: {screen['window_title']}"]
    if screen.get("url"):
        parts.append(f"URL: {screen['url']}")
    return "\n".join(parts)


def rss_mb() -> float:
    return psutil.Process(os.getpid()).memory_info().rss / 1e6


def mps_mb() -> dict:
    try:
        import torch

        return {
            "mps_allocated_mb": round(torch.mps.current_allocated_memory() / 1e6, 1),
            "mps_driver_mb": round(torch.mps.driver_allocated_memory() / 1e6, 1),
        }
    except Exception:  # noqa: BLE001
        return {}


def sync() -> None:
    try:
        import torch

        if torch.backends.mps.is_available():
            torch.mps.synchronize()
    except Exception:  # noqa: BLE001
        pass


@contextmanager
def timer(store: dict, key: str):
    sync()
    t = time.perf_counter()
    yield
    sync()
    store[key] = round(time.perf_counter() - t, 4)


def lat_summary(xs: list[float]) -> dict:
    xs = sorted(xs)
    if not xs:
        return {}
    p = lambda q: xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]  # noqa: E731
    return {"n": len(xs), "p50_s": round(p(0.5), 4), "p90_s": round(p(0.9), 4), "max_s": round(xs[-1], 4),
            "mean_s": round(statistics.mean(xs), 4)}


def accuracy(pairs: list[tuple[str, str]]) -> dict:
    n = len(pairs)
    ok = sum(1 for g, p in pairs if g == p)
    labels = sorted({g for g, _ in pairs} | {p for _, p in pairs})
    confusion = {g: {p: 0 for p in labels} for g in labels}
    for g, p in pairs:
        confusion[g][p] += 1
    return {"n": n, "correct": ok, "accuracy": round(ok / n, 3) if n else None, "confusion": confusion}


def binary_metrics(pairs: list[tuple[bool, float]], threshold: float = 0.5) -> dict:
    tp = sum(1 for g, s in pairs if g and s >= threshold)
    fn = sum(1 for g, s in pairs if g and s < threshold)
    fp = sum(1 for g, s in pairs if not g and s >= threshold)
    tn = sum(1 for g, s in pairs if not g and s < threshold)
    return {"threshold": threshold, "tp": tp, "fn": fn, "fp": fp, "tn": tn,
            "recall": round(tp / (tp + fn), 3) if tp + fn else None,
            "precision": round(tp / (tp + fp), 3) if tp + fp else None,
            "accuracy": round((tp + tn) / len(pairs), 3) if pairs else None}


def normalize_ja(s: str) -> str:
    return re.sub(r"[\s、。，．,.!！?？「」『』・:：]", "", s).lower()


def cer(ref: str, hyp: str) -> float:
    r, h = normalize_ja(ref), normalize_ja(hyp)
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)] / max(1, len(r))


def env_info() -> dict:
    import torch
    import transformers

    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip())
    return {"chip": chip, "memory_gb": round(mem / 2**30), "macos": platform.mac_ver()[0],
            "python": platform.python_version(), "torch": torch.__version__,
            "transformers": transformers.__version__}


def save(name: str, obj: dict) -> Path:
    p = RESULTS / f"{name}.json"
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved {p.relative_to(ROOT)}")
    return p


def free() -> None:
    gc.collect()
    try:
        import torch

        torch.mps.empty_cache()
    except Exception:  # noqa: BLE001
        pass
