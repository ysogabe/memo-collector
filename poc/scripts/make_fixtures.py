"""PoC 用フィクスチャ生成。

- fixtures/screens_src/*.html : 実アプリを模した画面モック（秘密情報はすべてダミー）
- fixtures/screens/*.png      : Chrome headless で 1440x900 にレンダリング
- fixtures/audio/*.wav        : macOS `say` で合成した日本語音声メモ（16kHz mono, d1-omni の入力要件）

実画面の screencapture は Screen Recording 権限が要るため、PoC では再現性重視でモックを使う。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "fixtures"
SRC = FIX / "screens_src"
PNG = FIX / "screens"
AUDIO = FIX / "audio"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
VOICES = ["Kyoko", "Eddy (日本語（日本）)", "Flo (日本語（日本）)", "Reed (日本語（日本）)"]

BASE_CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,'Hiragino Sans',sans-serif;width:1440px;height:900px;overflow:hidden;background:#fff;color:#1f2328;font-size:14px}
.chrome{height:76px;background:#dee1e6;border-bottom:1px solid #c4c7cc}
.tabs{height:36px;display:flex;align-items:flex-end;padding-left:80px}
.tab{background:#fff;border-radius:8px 8px 0 0;padding:8px 16px;width:260px;font-size:12px;white-space:nowrap;overflow:hidden}
.omni{height:40px;background:#fff;display:flex;align-items:center;padding:0 12px}
.omni .bar{flex:1;background:#f1f3f4;border-radius:16px;padding:6px 14px;font-size:13px;color:#333}
.mono{font-family:Menlo,monospace}
"""


def browser(tab: str, url: str, body: str, css: str = "") -> str:
    return f"""<html><head><meta charset=utf-8><style>{BASE_CSS}{css}</style></head><body>
<div class=chrome><div class=tabs><div class=tab>{tab}</div></div><div class=omni><div class=bar>{url}</div></div></div>
{body}</body></html>"""


def page(body: str, css: str) -> str:
    return f"<html><head><meta charset=utf-8><style>{BASE_CSS}{css}</style></head><body>{body}</body></html>"


SCREENS: dict[str, str] = {}

SCREENS["s01"] = browser(
    "Support streaming events · Issue #128",
    "github.com/opendots/opendots/issues/128",
    """<div style="padding:20px 40px;border-bottom:1px solid #d0d7de"><b>opendots</b> / <b>opendots</b> &nbsp; <span style="color:#57606a">Code &nbsp; Issues 42 &nbsp; Pull requests 7 &nbsp; Actions</span></div>
<div style="padding:24px 40px"><h1 style="font-weight:400;font-size:30px">Support streaming events in adapter API <span style="color:#57606a">#128</span></h1>
<p style="margin:12px 0"><span style="background:#1f883d;color:#fff;border-radius:16px;padding:4px 12px">Open</span> &nbsp; <b>kmori</b> opened this issue 3 days ago · 5 comments</p>
<div style="border:1px solid #d0d7de;border-radius:6px;margin-top:16px;width:900px"><div style="background:#f6f8fa;padding:10px">kmori commented 3 days ago</div>
<div style="padding:16px;line-height:1.7">Currently adapters can only return a single response. We need <code>AsyncIterator&lt;Event&gt;</code> support so that agents (e.g. Hermes) can receive partial results.<br><br>
<b>Proposal</b><ul style="margin-left:24px"><li>Add <code>stream()</code> to <code>Adapter</code> interface</li><li>Backpressure via <code>highWaterMark</code></li><li>Keep <code>call()</code> for backwards compatibility</li></ul></div></div>
<div style="margin-top:16px;color:#57606a">Labels: <span style="background:#a2eeef;padding:2px 8px;border-radius:10px">enhancement</span> <span style="background:#d4c5f9;padding:2px 8px;border-radius:10px">adapter</span></div></div>""",
)

SCREENS["s02"] = page(
    """<div style="height:40px;background:#1a1a1a;color:#ddd;display:flex;align-items:center;padding:0 16px;font-size:13px">Zoom Meeting &nbsp; <span style="color:#3fb950">● 録画していません</span><span style="margin-left:auto">ギャラリービュー</span></div>
<div style="display:flex;height:780px;background:#232323;padding:12px;gap:12px">
<div style="flex:3;background:#fff;border-radius:6px;padding:48px"><div style="color:#0b5cad;font-size:14px">共有画面: 佐藤 健</div><h1 style="font-size:44px;margin:24px 0">API移行計画 Q4</h1>
<ul style="font-size:24px;line-height:2;margin-left:30px"><li>v1 REST → v2 GraphQL へ段階移行</li><li>認証: 独自トークン → OAuth 2.1</li><li>11月末に v1 を deprecated</li><li>移行ガイドを10月中に公開</li></ul></div>
<div style="flex:1;display:flex;flex-direction:column;gap:12px">""" + "".join(
        f'<div style="flex:1;background:#3a3a3a;border-radius:6px;color:#fff;display:flex;align-items:flex-end;padding:8px">{n}</div>'
        for n in ["佐藤 健", "田中 美咲", "Yoshio", "鈴木 大輔", "Li Wei"]
    ) + """</div></div>
<div style="height:80px;background:#1a1a1a;color:#ddd;display:flex;justify-content:center;gap:40px;align-items:center;font-size:13px"><span>🎤 ミュート解除</span><span>📹 ビデオの開始</span><span>👥 参加者 5</span><span>💬 チャット</span><span>⬆ 画面共有</span><span style="background:#e02828;color:#fff;padding:6px 14px;border-radius:6px">退出</span></div>""",
    "",
)

CODE_CSS = """.ed{display:flex;height:900px;background:#1e1e1e;color:#d4d4d4}.side{width:260px;background:#252526;padding:12px;font-size:13px;line-height:1.9;color:#ccc}
.main{flex:1}.tabbar{height:36px;background:#2d2d2d;display:flex}.t{padding:9px 16px;background:#1e1e1e;color:#fff;font-size:13px}
pre{font-family:Menlo,monospace;font-size:14px;line-height:1.6;padding:12px 0}.ln{color:#858585;display:inline-block;width:50px;text-align:right;margin-right:20px}
.k{color:#569cd6}.s{color:#ce9178}.f{color:#dcdcaa}.c{color:#6a9955}.err{text-decoration:underline wavy #f14c4c}"""


def code_lines(lines: list[str], start: int = 1) -> str:
    return "".join(f'<span class=ln>{i}</span>{l}\n' for i, l in enumerate(lines, start))


SCREENS["s03"] = page(
    f"""<div class=ed><div class=side>EXPLORER<br>▾ MACH-RUNTIME<br>&nbsp;▾ src<br>&nbsp;&nbsp;&nbsp;adapter.ts<br>&nbsp;&nbsp;&nbsp;registry.ts<br>&nbsp;&nbsp;&nbsp;stream.ts<br>&nbsp;▸ test<br>&nbsp;package.json</div>
<div class=main><div class=tabbar><div class=t>adapter.ts</div></div><pre>{code_lines([
        '<span class=k>import</span> { Registry } <span class=k>from</span> <span class=s>"./registry"</span>;',
        '',
        '<span class=k>export async function</span> <span class=f>resolveAdapter</span>(name: <span class=k>string</span>, reg: Registry) {',
        '  <span class=k>const</span> entry = reg.<span class=f>lookup</span>(name);',
        '  <span class=c>// TODO: entry may be undefined when plugin failed to load</span>',
        '  <span class=k>const</span> cfg = <span class="err">entry.config</span>;',
        '  <span class=k>const</span> timeout: <span class=k>number</span> = <span class="err">cfg.timeout ?? "30s"</span>;',
        '  <span class=k>return new</span> <span class=f>AdapterClient</span>(cfg.endpoint, { timeout });',
        '}',
        '',
        '<span class=k>export function</span> <span class=f>toEvent</span>(raw: <span class=k>unknown</span>): Event {',
        '  <span class=k>return</span> JSON.<span class=f>parse</span>(raw <span class=k>as string</span>);',
        '}',
    ], 118)}</pre>
<div style="position:absolute;bottom:0;width:1180px;height:180px;background:#1e1e1e;border-top:1px solid #444;padding:10px;font-size:13px">PROBLEMS 2<br><br><span style="color:#f14c4c">⊗</span> 'entry' is possibly 'undefined'. ts(18048) [Ln 123, Col 15]<br><span style="color:#f14c4c">⊗</span> Type 'string | number' is not assignable to type 'number'. ts(2322) [Ln 124, Col 9]</div></div></div>""",
    CODE_CSS,
)

SCREENS["s04"] = page(
    """<div style="height:52px;background:#ececec;border-bottom:1px solid #ccc;display:flex;align-items:center;padding-left:90px;font-size:13px">pso-survey-2026.pdf — 3 / 24 ページ</div>
<div style="background:#808080;height:848px;display:flex;justify-content:center;padding-top:20px"><div style="background:#fff;width:820px;padding:56px 70px;font-family:'Times New Roman',serif;line-height:1.5">
<h2 style="text-align:center;font-size:22px">A Survey of Particle Swarm Optimization Variants (2016–2026)</h2><p style="text-align:center;margin:8px 0 20px">A. Kumar, M. Ito, R. Fischer</p>
<p style="font-weight:bold">3. Velocity Update Rules</p><p style="text-align:justify">The canonical PSO updates the velocity of particle i as v<sub>i</sub>(t+1) = ω v<sub>i</sub>(t) + c<sub>1</sub>r<sub>1</sub>(p<sub>i</sub> − x<sub>i</sub>) + c<sub>2</sub>r<sub>2</sub>(g − x<sub>i</sub>). Adaptive inertia weight schemes reduce premature convergence ...</p>
<div style="border:1px solid #333;height:260px;margin:20px 0;display:flex;align-items:flex-end;gap:18px;padding:20px">""" + "".join(
        f'<div style="flex:1;background:#4a6fa5;height:{h}%"></div>' for h in [80, 62, 45, 33, 27, 22, 20]
    ) + """</div><p style="text-align:center;font-size:13px">Figure 2. Convergence of APSO, CLPSO and QPSO on Rastrigin (30-D).</p></div></div>""",
    "",
)

TERM_CSS = """.term{background:#1d1f21;color:#c5c8c6;height:900px}.tb{height:28px;background:#38393b;color:#bbb;text-align:center;font-size:12px;line-height:28px}
pre{font-family:Menlo,monospace;font-size:14px;line-height:1.5;padding:12px}.r{color:#cc6666}.g{color:#b5bd68}.y{color:#f0c674}"""

SCREENS["s05"] = page(
    """<div class=term><div class=tb>yoshio — pytest — 120×40</div><pre>
<span class=g>yoshio@mbp</span> mach-runtime % uv run pytest tests/test_stream.py -q
<span class=g>....</span><span class=r>F</span><span class=g>..</span><span class=r>F</span>
=================================== FAILURES ===================================
<span class=r>________________________ test_backpressure_high_water_mark ________________________</span>

    def test_backpressure_high_water_mark():
        s = Stream(high_water_mark=4)
        for i in range(10):
            s.push(i)
<span class=r>&gt;       assert s.paused is True
E       AssertionError: assert False is True
E        +  where False = &lt;Stream buffered=10&gt;.paused</span>

tests/test_stream.py:42: AssertionError
<span class=r>____________________________ test_event_roundtrip _____________________________</span>
<span class=r>E       json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)</span>
tests/test_stream.py:77: JSONDecodeError
=========================== short test summary info ============================
<span class=r>FAILED</span> tests/test_stream.py::test_backpressure_high_water_mark
<span class=r>FAILED</span> tests/test_stream.py::test_event_roundtrip
<span class=r>========================= 2 failed, 6 passed in 0.41s ==========================</span>
<span class=g>yoshio@mbp</span> mach-runtime % █</pre></div>""",
    TERM_CSS,
)

SCREENS["s06"] = page(
    """<div style="display:flex;height:900px"><div style="width:260px;background:#3f0e40;color:#cfc3cf;padding:16px;line-height:2.1;font-size:15px"><b style="color:#fff">Acme Inc.</b><br># general<br><span style="background:#1164a3;color:#fff;padding:2px 6px;border-radius:4px"># proj-hermes</span><br># random<br>● 田中 美咲<br>● 佐藤 健</div>
<div style="flex:1;padding:0"><div style="height:56px;border-bottom:1px solid #ddd;padding:16px 20px;font-weight:bold"># proj-hermes</div><div style="padding:20px;line-height:1.7;font-size:15px">""" + "".join(
        f'<div style="margin-bottom:22px"><b>{n}</b> <span style="color:#888;font-size:12px">{t}</span><br>{m}</div>'
        for n, t, m in [
            ("田中 美咲", "10:12", "Hermes の OpenDots アダプタ、ストリーミング対応のスコープを決めたいです。来週どこかで 30 分もらえますか？"),
            ("佐藤 健", "10:20", "API 移行のガイド草案を Notion に上げました。レビューお願いします 🙏"),
            ("田中 美咲", "10:41", "@Yoshio 先日の見積もりの件、金曜までにご返信いただけると助かります。"),
            ("鈴木 大輔", "11:03", "CI が flaky なので test_stream を一時的に skip しています"),
        ]
    ) + """</div><div style="position:absolute;bottom:20px;left:280px;width:1140px;border:1px solid #aaa;border-radius:8px;padding:14px;color:#888"># proj-hermes へのメッセージ</div></div></div>""",
    "",
)

SCREENS["s07"] = page(
    f"""<div class=ed><div class=side>EXPLORER<br>▾ MACH-RUNTIME<br>&nbsp;▸ src<br>&nbsp;.env<br>&nbsp;.env.example<br>&nbsp;package.json</div>
<div class=main><div class=tabbar><div class=t>.env</div></div><pre>{code_lines([
        '<span class=c># local development secrets — DO NOT COMMIT</span>',
        'NODE_ENV=development',
        'DATABASE_URL=postgres://mach:<span class=s>Pg-Dev-Pass-2026!</span>@localhost:5432/mach',
        'OPENAI_API_KEY=<span class=s>sk-proj-FAKEa1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ0123</span>',
        'ANTHROPIC_API_KEY=<span class=s>sk-ant-api03-FAKExYz987654321AbCdEfGhIjKlMnOpQr</span>',
        'STRIPE_SECRET_KEY=<span class=s>sk_live_FAKE51Hc2kLmN0pQrStUvWxYz</span>',
        'HERMES_ENDPOINT=http://127.0.0.1:8787',
    ])}</pre></div></div>""",
    CODE_CSS,
)

SCREENS["s08"] = browser(
    "IAM Management Console",
    "us-east-1.console.aws.amazon.com/iam/home#/users/details/deploy-bot/create-access-key",
    """<div style="height:44px;background:#232f3e;color:#fff;padding:12px 20px;font-size:14px"><b>aws</b> &nbsp; Services &nbsp; 🔍 Search</div>
<div style="padding:30px 60px"><div style="color:#0972d3;font-size:13px">IAM › Users › deploy-bot › Create access key</div><h1 style="font-size:28px;margin:12px 0">Retrieve access keys</h1>
<div style="border:1px solid #e9ebed;border-radius:12px;padding:24px;width:1100px"><div style="background:#f2f8fd;border:1px solid #0972d3;padding:12px;border-radius:8px;margin-bottom:20px">ⓘ This is the only time that the secret access key can be viewed or downloaded. You cannot recover it later.</div>
<table style="width:100%;font-size:15px"><tr style="color:#5f6b7a"><td>Access key</td><td>Secret access key</td></tr><tr><td class=mono>AKIAFAKE7Q3EXAMPLE2X</td><td class=mono>wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKEKEY9zq</td></tr></table>
<button style="margin-top:24px;padding:8px 18px;border-radius:16px;border:2px solid #0972d3;background:#fff;color:#0972d3">Download .csv file</button></div></div>""",
)

SCREENS["s09"] = page(
    """<div style="height:48px;background:#292929;color:#fff;display:flex;align-items:center;padding:0 16px;gap:24px;font-size:13px"><b>Design Review</b><span>00:23:41</span><span style="margin-left:auto">💬 チャット</span><span>👥 参加者</span><span>✋ 挙手</span><span>🎤</span><span>📷</span><span style="background:#c4314b;padding:6px 14px;border-radius:4px">退出</span></div>
<div style="display:flex;height:852px;background:#1f1f1f;padding:10px;gap:10px"><div style="flex:1;background:#fff;padding:40px"><div style="color:#666;font-size:13px">佐藤 健 が画面を共有しています</div>
<h1 style="margin:16px 0">Context Capture 設計書 v0.3 — データフロー</h1><div style="display:flex;gap:20px;align-items:center;margin-top:40px;font-size:18px">""" + "".join(
        f'<div style="border:2px solid #4a6fa5;border-radius:8px;padding:20px 24px">{b}</div><div>→</div>' for b in ["Hotkey", "Screenshot + Mic", "STT", "Context Record", "Inbox"]
    ) + """</div><p style="margin-top:50px;font-size:18px;line-height:2">・レビュー期限: 10/9 (木)<br>・次回定例: 10/15 (水) 10:00〜</p></div>
<div style="width:260px;display:flex;flex-direction:column;gap:10px">""" + "".join(
        f'<div style="flex:1;background:#3b3a39;color:#fff;border-radius:6px;padding:8px;display:flex;align-items:flex-end">{n}</div>' for n in ["佐藤 健", "Yoshio", "Li Wei"]
    ) + "</div></div>",
    "",
)

SCREENS["s10"] = browser(
    "Amazon.co.jp: USB-C ケーブル 2m 240W",
    "amazon.co.jp/dp/B0EXAMPLE1",
    """<div style="height:60px;background:#131921;color:#fff;padding:18px 20px;font-size:20px"><b>amazon</b>.co.jp &nbsp; <span style="background:#fff;color:#333;padding:4px 300px 4px 10px;font-size:14px;border-radius:4px">検索 Amazon.co.jp</span></div>
<div style="display:flex;padding:30px 40px;gap:40px"><div style="width:420px;height:420px;background:#f3f3f3;display:flex;align-items:center;justify-content:center;font-size:120px">🔌</div>
<div style="width:560px"><h1 style="font-size:24px;font-weight:400;line-height:1.4">USB-C to USB-C ケーブル 2m 240W 急速充電 USB4 40Gbps 8K映像出力 編組ナイロン</h1><div style="color:#007185;margin:8px 0">★★★★☆ 2,384個の評価</div>
<div style="font-size:30px;margin:16px 0">￥2,480</div><ul style="margin-left:20px;line-height:1.9"><li>USB4 Gen3 40Gbps データ転送</li><li>最大240W PD 3.1 急速充電</li><li>Thunderbolt 3 互換（Thunderbolt 4 認証なし）</li></ul></div>
<div style="width:240px;border:1px solid #ddd;border-radius:8px;padding:18px"><div style="font-size:22px">￥2,480</div><div style="color:#007600;margin:10px 0">在庫あり</div><div style="background:#ffd814;border-radius:20px;padding:8px;text-align:center;margin:8px 0">カートに入れる</div><div style="background:#ffa41c;border-radius:20px;padding:8px;text-align:center">今すぐ買う</div></div></div>""",
)

SCREENS["s11"] = page(
    """<div class=term><div class=tb>yoshio — zsh — 120×40</div><pre>
<span class=g>yoshio@mbp</span> ~ % gh auth status
github.com
  <span class=r>X Failed to log in to github.com account yoshio (/Users/yoshio/.config/gh/hosts.yml)</span>
  - The token in /Users/yoshio/.config/gh/hosts.yml is invalid.
<span class=g>yoshio@mbp</span> ~ % cat ~/.config/gh/hosts.yml
github.com:
    users:
        yoshio:
            oauth_token: <span class=y>gho_FAKE16C7e42F292c6912E7710c838347Ae178B4a</span>
    git_protocol: https
    oauth_token: <span class=y>gho_FAKE16C7e42F292c6912E7710c838347Ae178B4a</span>
    user: yoshio
<span class=g>yoshio@mbp</span> ~ % █</pre></div>""",
    TERM_CSS,
)

SCREENS["s12"] = page(
    """<div style="display:flex;height:900px"><div style="width:240px;background:#f7f7f5;padding:16px;font-size:14px;line-height:2;color:#5f5e5b">Yoshio のワークスペース<br>📄 ホーム<br>📁 Hermes<br>&nbsp;&nbsp;📄 <b style="color:#37352f">Context Record 仕様 v0.3</b><br>&nbsp;&nbsp;📄 Adapter 一覧<br>📁 個人</div>
<div style="flex:1;padding:60px 120px;color:#37352f"><div style="font-size:60px">🧩</div><h1 style="font-size:40px;margin:10px 0 24px">Context Record 仕様 v0.3</h1>
<p style="line-height:1.8;font-size:16px">1 回のホットキー操作で保存されるレコード。入力時には分類を要求しない。</p>
<table style="border-collapse:collapse;margin-top:24px;font-size:15px;width:900px">""" + "".join(
        f'<tr><td style="border:1px solid #e9e9e7;padding:8px" class=mono>{a}</td><td style="border:1px solid #e9e9e7;padding:8px">{b}</td><td style="border:1px solid #e9e9e7;padding:8px">{c}</td></tr>'
        for a, b, c in [
            ("<b>field</b>", "<b>type</b>", "<b>説明</b>"),
            ("captured_at", "datetime", "キャプチャ時刻 (ISO8601)"),
            ("app_bundle_id", "string", "前面アプリ"),
            ("window_title", "string", "フォーカス中ウインドウ"),
            ("url", "string?", "取得できた場合のみ"),
            ("screenshot_path", "string", "WebP, ウインドウ単位"),
            ("annotation_text", "string", "STT 結果"),
            ("intent", "enum?", "後段で推定 (todo/research/code/note/schedule)"),
        ]
    ) + "</table></div></div>",
    "",
)

SCREENS["s13"] = page(
    """<div style="display:flex;height:900px;background:#fff"><div style="width:250px;background:#f3f4f6;padding:16px;line-height:2.2;font-size:14px">🔐 1Password<br>すべてのアイテム<br>お気に入り<br>ログイン<br>クレジットカード</div>
<div style="width:340px;border-right:1px solid #e5e7eb;padding:12px;font-size:14px;line-height:3"><div style="background:#dbeafe;padding:0 8px;border-radius:6px">🌐 GitHub<br></div>🌐 AWS (root)<br>🌐 Google<br>🏦 みずほダイレクト</div>
<div style="flex:1;padding:40px"><h1 style="font-size:28px">🌐 GitHub</h1><div style="margin-top:30px;border:1px solid #e5e7eb;border-radius:10px;width:640px">
<div style="padding:14px;border-bottom:1px solid #e5e7eb"><div style="color:#6b7280;font-size:12px">ユーザー名</div>yoshio@example.com</div>
<div style="padding:14px;border-bottom:1px solid #e5e7eb"><div style="color:#6b7280;font-size:12px">パスワード <span style="color:#2563eb">（表示中）</span></div><span class=mono style="font-size:18px">Tr0ub4dor&amp;3-Fake-Horse!</span></div>
<div style="padding:14px"><div style="color:#6b7280;font-size:12px">ワンタイムパスワード</div><span class=mono style="font-size:20px">482 913</span> ⏱ 17</div></div>
<div style="margin-top:16px;color:#6b7280">ウェブサイト: github.com &nbsp; 最終更新: 2024年3月2日</div></div></div>""",
    "",
)

SCREENS["s14"] = browser(
    "Google カレンダー - 2026年10月",
    "calendar.google.com/calendar/u/0/r/month",
    """<div style="height:64px;border-bottom:1px solid #ddd;padding:18px 24px;font-size:22px;color:#3c4043">📅 カレンダー &nbsp; <span style="font-size:14px;border:1px solid #ccc;padding:6px 12px;border-radius:4px">今日</span> &nbsp; 2026年 10月</div>
<div style="display:grid;grid-template-columns:repeat(7,1fr);height:760px">""" + "".join(
        f'<div style="border:1px solid #eee;padding:4px;font-size:12px;color:#3c4043">{h}</div>' for h in ["日", "月", "火", "水", "木", "金", "土"]
    ) + "".join(
        f'<div style="border:1px solid #eee;padding:6px;font-size:12px">{d if 1 <= d <= 31 else ""}'
        + ({8: '<div style="background:#1a73e8;color:#fff;border-radius:4px;padding:2px 4px;margin-top:4px">10:00 定例</div>',
            15: '<div style="background:#1a73e8;color:#fff;border-radius:4px;padding:2px 4px;margin-top:4px">10:00 定例</div>',
            20: '<div style="background:#33b679;color:#fff;border-radius:4px;padding:2px 4px;margin-top:4px">出張 (大阪)</div>'}.get(d, ""))
        + "</div>"
        for d in range(-3, 39)
    ) + "</div>",
)


def render_screens() -> None:
    SRC.mkdir(parents=True, exist_ok=True)
    PNG.mkdir(parents=True, exist_ok=True)
    for sid, html in SCREENS.items():
        src = SRC / f"{sid}.html"
        src.write_text(html, encoding="utf-8")
        out = PNG / f"{sid}.png"
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--window-size=1440,900", f"--screenshot={out}", src.as_uri()],
            check=True, capture_output=True,
        )
        print("screen", out.name)


def render_audio() -> None:
    AUDIO.mkdir(parents=True, exist_ok=True)
    data = json.loads((FIX / "dataset.json").read_text(encoding="utf-8"))
    for c in data["captures"]:
        voice = VOICES[c["id"] % len(VOICES)]
        wav = AUDIO / f"c{c['id']:02d}.wav"
        # ffmpeg 非依存: say が直接 16kHz/16bit/mono の WAV を書く
        subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "--channels=1",
                        "-o", str(wav), c["text"]], check=True)
        print("audio", wav.name, voice)


if __name__ == "__main__":
    what = sys.argv[1:] or ["screens", "audio"]
    if "screens" in what:
        render_screens()
    if "audio" in what:
        render_audio()
