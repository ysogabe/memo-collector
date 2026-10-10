// ヒーローのデモ: 押す → 撮影枠 + 録音 HUD → 離す → 保存トースト → Inbox に 1 行増える（意図は少し遅れて付く）
(() => {
  const scenes = [
    { shot: "s01", app: "Chrome", title: "Support streaming events · Issue #128", text: "これ Hermes のアダプタに使えそう。あとで実装方法を調べる", intent: "research" },
    { shot: "s03", app: "VS Code", title: "adapter.ts — mach-runtime", text: "ここで null になる理由を調べて直しておいて", intent: "code" },
    { shot: "s02", app: "Zoom", title: "Zoom Meeting", text: "今の API 移行の話、認証設計にも関係する。あとで確認", intent: "todo" },
    { shot: "s04", app: "プレビュー", title: "pso-survey-2026.pdf", text: "この論文、PSO のところを明日までに読む", intent: "todo" },
    { shot: "s11", app: "ターミナル", title: "yoshio — zsh", text: "gh の認証トークンが古い。あとで更新する", intent: "todo", secret: true },
  ];
  const seed = [
    { time: "18:05", app: "Slack", text: "田中さんへの返信、金曜までにする", intent: "todo" },
    { time: "16:40", app: "Notion", text: "この仕様、キャプチャのデータ構造の参考になる", intent: "note" },
  ];

  const $ = (id) => document.getElementById(id);
  const demo = $("demo"), shot = $("demo-shot"), title = $("demo-title"), hudText = $("demo-hud-text");
  const toast = $("demo-toast"), inbox = $("demo-inbox"), hold = $("demo-hold");
  if (!demo) return;

  let i = 0, pressedAt = 0, typing = null, busy = false, clock = new Date(2026, 9, 8, 21, 30);

  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const hhmm = (d) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  function row({ time, app, text, intent, secret }, isNew) {
    const li = document.createElement("li");
    if (isNew) li.className = "is-new";
    li.innerHTML = `<time>${time}</time><span class="app">${esc(app)}</span><span class="txt">${esc(text)}</span>` +
      `<span class="lbl">${isNew ? "" : `<span class="tag">${intent}</span>`}</span>`;
    return li;
  }
  seed.forEach((s) => inbox.append(row(s, false)));

  function show(scene) {
    demo.classList.remove("is-capturing");
    shot.src = `assets/${scene.shot}.jpg`;
    shot.alt = `${scene.app} の画面`;
    title.textContent = scene.title;
  }
  // 次のシーン画像を先読み
  scenes.forEach((s) => { const im = new Image(); im.src = `assets/${s.shot}.jpg`; });

  function start() {
    if (busy || pressedAt) return;
    pressedAt = performance.now();
    hold.setAttribute("aria-pressed", "true");
    toast.classList.remove("is-shown");
    demo.classList.remove("is-capturing");
    void demo.offsetWidth; // アニメーションを再生し直す
    demo.classList.add("is-capturing", "is-recording");
    hudText.textContent = "話してください";
    const text = scenes[i].text;
    let n = 0;
    typing = setTimeout(function tick() {
      n += 1;
      hudText.textContent = text.slice(0, n);
      if (n < text.length) typing = setTimeout(tick, 55);
    }, 450);
  }

  function stop() {
    if (!pressedAt) return;
    const held = performance.now() - pressedAt;
    pressedAt = 0;
    clearTimeout(typing);
    hold.setAttribute("aria-pressed", "false");
    demo.classList.remove("is-recording");
    if (held < 600) {
      toast.className = "toast is-shown";
      toast.innerHTML = "<b>押したまま話してください</b><span class=\"src\">短すぎる録音は保存しません</span>";
      return;
    }
    busy = true;
    const scene = scenes[i];
    clock = new Date(clock.getTime() + 7 * 60 * 1000);
    const time = hhmm(clock);
    setTimeout(() => {
      toast.className = "toast is-shown";
      toast.innerHTML = `<b>保存しました</b><span class="src">${esc(scene.app)} · ${esc(scene.title)}</span><br>「${esc(scene.text)}」`;
      const li = row({ time, ...scene }, true);
      inbox.prepend(li);
      while (inbox.children.length > 5) inbox.lastElementChild.remove();
      // 意図と秘密情報チェックは保存後に非同期で付く
      setTimeout(() => {
        li.querySelector(".lbl").innerHTML = (scene.secret ? '<span class="tag warn">要確認</span> ' : "") +
          `<span class="tag">${scene.intent}</span>`;
        if (scene.secret) {
          toast.className = "toast is-shown is-warn";
          toast.innerHTML = "<b>要確認</b><span class=\"src\">トークンらしき文字列が写っています。確認するまでエージェントには渡しません</span>";
        }
        i = (i + 1) % scenes.length;
        setTimeout(() => { show(scenes[i]); busy = false; }, scene.secret ? 2200 : 1200);
      }, 900);
    }, 650);
  }

  hold.addEventListener("pointerdown", (e) => { e.preventDefault(); hold.setPointerCapture(e.pointerId); start(); });
  hold.addEventListener("pointerup", stop);
  hold.addEventListener("pointercancel", stop);
  hold.addEventListener("keydown", (e) => { if ((e.key === " " || e.key === "Enter") && !e.repeat) { e.preventDefault(); start(); } });
  hold.addEventListener("keyup", (e) => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); stop(); } });

  // ページ上でも Space 長押しで試せる（入力欄・ボタン・summary にフォーカスがあるときは除く）
  const typingTarget = (el) => el.closest("input, textarea, select, button, summary, a, [contenteditable]");
  document.addEventListener("keydown", (e) => {
    if (e.code !== "Space" || e.repeat || typingTarget(e.target)) return;
    const r = demo.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) return; // デモが見えていないときは通常のスクロール
    e.preventDefault();
    start();
  });
  document.addEventListener("keyup", (e) => { if (e.code === "Space" && !typingTarget(e.target)) stop(); });
})();
