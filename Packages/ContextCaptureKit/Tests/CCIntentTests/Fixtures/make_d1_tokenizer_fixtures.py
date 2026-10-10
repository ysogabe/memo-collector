"""d1-3B トークナイザの参照トークン列を作る（Swift の D1Tokenizer / D1Prompt との一致テスト用）。

usage（リポジトリのルートで）:
  poc/.venv/bin/python -I Packages/ContextCaptureKit/Tests/CCIntentTests/Fixtures/make_d1_tokenizer_fixtures.py \
      ~/.cache/huggingface/hub/models--LiquidAI--d1-3B/snapshots/051bcc464b01b9f92942b364d9586b0ef5912432 \
      Packages/ContextCaptureKit/Tests/CCIntentTests/Fixtures/d1_tokenizer_cases.json

- HF `tokenizers`（Rust 実装）で、生テキストと d1 のプロンプト全文（INTENT_Q_EN / DEADLINE_Q）を encode する。
- プロンプト文字列は d1 の `prompt.py`（同じ snapshot の `render`）で作る。readout_ids も同じモジュールから取る。
  prompt.py は副作用のない純 Python（読んで確認済み）。tokenizer は `encode(text, add_special_tokens=False)` だけを使う。
- 質問文は poc/scripts/common.py の INTENT_Q_EN / DEADLINE_Q と同じ（ここに写してある。変えたら両方直す）。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import tokenizers
from tokenizers import Tokenizer

snap, out = Path(sys.argv[1]).expanduser(), Path(sys.argv[2])

spec = importlib.util.spec_from_file_location("d1_prompt", snap / "prompt.py")
prompt = importlib.util.module_from_spec(spec)
sys.modules["d1_prompt"] = prompt
spec.loader.exec_module(prompt)

rust = Tokenizer.from_file(str(snap / "tokenizer.json"))


class Tok:
    """prompt.py が要る最小 API（transformers の tokenizer.encode 互換）。"""

    def encode(self, text, add_special_tokens=False):
        return rust.encode(text, add_special_tokens=add_special_tokens).ids


tok = Tok()

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
DEADLINE_Q = {
    "type": "noul",
    "instructions": "Does the note mention a date, day of the week or time (a deadline or an appointment)?",
}
QS = {"intent": prompt.as_question(INTENT_Q_EN), "deadline": prompt.as_question(DEADLINE_Q)}
BOS = "<|startoftext|>"

CASES = [
    # 句読点で終わる文（テンプレートの "\n\n\n" と同じ前分割片にまとまる）
    "あとで調べる。", "これ何？", "すごい！", "Check this.", "Really?", "Wow!", "fix it...", "メモ：", "（参考）",
    "引用「これ」", "end;", "a,", "tilde~", "path/", "100%", "$5", "ok)", "ok]", "ok}", "#tag", "@user",
    "foo:", "完了。。。", "疑問？！",
    # 絵文字・記号
    "😀", "これ最高😀", "👍🏽了解", "👨‍👩‍👧 家族旅行の予約", "🇯🇵の祝日を確認", "☕️休憩", "→次へ", "★重要",
    # 英数字混在
    "PR#123をレビュー", "v2.3.1にアップデート", "2026/10/10 15:00に会議", "10月15日の10時から", "3時",
    "OAuth2.0のトークン", "GPT-4oとClaude 3.5を比較", "API_KEYを更新", "it's done", "I'LL DO IT", "we've", "they're",
    "12345678", "１２３全角数字", "ＡＢＣ全角英字", "x=1+2*3", "https://example.com/a?b=c&d=e", "foo_bar.baz()",
    "`npm install`して", "C++とC#", "e.g. this", "Dr. Smith", "ﾊﾝｶｸｶﾅ",
    # 改行・空白を含む注釈
    "一行目\n二行目", "一行目\n\n二行目", "一行目\n\n\n\n三行あけ", "末尾改行\n", "末尾2改行\n\n", "\n先頭改行",
    "CRLF\r\n改行", "タブ\t区切り", "全角　スペース", "末尾全角スペース　", "NBSP here", "  先頭スペース",
    "末尾スペース  ", "複数   スペース", "句点。\n次の行", "？\n\n", "a.\n\nb",
    # 空に近い文字列
    "", " ", "  ", "\n", "\n\n", "　", "a", "あ", "。", ".", "?", "\t", "​",
    # 合成文字・正規化（normalizer なし: NFC/NFD はそのまま別列になるはず）
    "が", "が", "é", "Ａ",
    # 特殊トークンの文字列（HF は追加トークンとして切り出す）
    "<|im_end|>を含む", "<think>考え</think>", "<|startoftext|>",
    # 長め・混在
    "このPRのCIが落ちてる。test_parser.pyの3行目、たぶんNoneチェック漏れ。Claude Codeに直してもらう",
    "明日(10/11)の14:00〜15:30、佐藤さんと1on1。資料は https://docs.example.com/x を見る",
]

rows = []
for text in CASES:
    row = {"text": text, "ids": tok.encode(text), "prompts": {}}
    for name, q in QS.items():
        p = prompt.render(tok, text, q, bos=BOS)
        row["prompts"][name] = {"prompt": p, "ids": tok.encode(p)}
    rows.append(row)

out.write_text(json.dumps({
    "generator": "make_d1_tokenizer_fixtures.py",
    "tokenizers_version": tokenizers.__version__,
    "snapshot": snap.name,
    "readout_ids": {name: prompt.readout_ids(tok, q) for name, q in QS.items()},
    "cases": rows,
}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
print("wrote", out, len(rows), "cases")
