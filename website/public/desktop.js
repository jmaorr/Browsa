// The Mac pages: a drawn model of Browsa's window, built from the real app's layout (sidebar,
// page, panel, ⌘K), standing in for footage until there's a clip. Every frame in a page with
// `data-mw` gets one, and the scenes are pure CSS states on its `data-scene` and `data-space`.

const WINDOW = `
<div class="mw-side">
  <div class="mw-lights"><i></i><i></i><i></i></div>
  <div class="mw-addr"><i class="mw-lock"></i><span class="mw-url">linear.app</span><span class="mw-exts"><i></i><i></i><i class="hot"></i></span></div>
  <div class="mw-favs"><b class="f1"></b><b class="f2"></b><b class="f3"></b><b class="f4"></b></div>
  <div class="mw-spacename"><span class="p">Personal</span><span class="w">Work</span></div>
  <div class="mw-rule"></div>
  <div class="mw-newtab"><i></i>New Tab</div>
  <div class="mw-tabs p">
    <div class="mw-tab on"><i class="c1"></i><span>Linear</span></div>
    <div class="mw-tab"><i class="c2"></i><span>Figma</span></div>
    <div class="mw-tab"><i class="c3"></i><span>Notion</span></div>
    <div class="mw-tab"><i class="c4"></i><span>Framer</span></div>
  </div>
  <div class="mw-tabs w">
    <div class="mw-tab on"><i class="c5"></i><span>Pull requests</span></div>
    <div class="mw-tab"><i class="c6"></i><span>Standup notes</span></div>
    <div class="mw-tab"><i class="c7"></i><span>localhost:3000</span></div>
  </div>
  <div class="mw-sect">
    <div class="mw-sect-h">Dev servers</div>
    <div class="mw-sect-r"><i></i><span>checkout-web</span><em>3000</em></div>
    <div class="mw-sect-r"><i></i><span>pay-button</span><em>3001</em></div>
    <div class="mw-sect-r off"><i></i><span>api</span><em>8080</em></div>
  </div>
  <div class="mw-foot"><i class="dl"></i><span class="mw-dots"><i class="p"></i><i class="w"></i></span><i class="plus"></i></div>
</div>
<div class="mw-page">
  <div class="mw-site p">
    <div class="mw-nav"><b></b><i></i><i></i><i></i><u></u></div>
    <div class="mw-hero"><b></b><b></b><i></i></div>
    <div class="mw-art"></div>
    <div class="mw-cards"><b></b><b></b><b></b></div>
  </div>
  <div class="mw-site w">
    <div class="mw-nav"><b></b><i></i><i></i><u></u></div>
    <div class="mw-list"><b></b><b></b><b></b><b></b><b></b></div>
  </div>
  <span class="mw-agentchip">Agent</span>
  <i class="mw-cursor"></i>
</div>
<div class="mw-panel">
  <div class="mw-pane notes">
    <div class="mw-pane-h">Notes</div>
    <div class="mw-note"><b></b><i></i><i></i></div>
    <div class="mw-note"><b></b><i></i></div>
    <div class="mw-note me"><i></i><i></i></div>
  </div>
  <div class="mw-pane agents">
    <div class="mw-pane-h">Agents <span class="mw-stop">Stop</span></div>
    <div class="mw-feed"><i></i><span>page_read</span><em>localhost</em></div>
    <div class="mw-feed"><i></i><span>page_click</span><em>Sign in</em></div>
    <div class="mw-feed"><i></i><span>page_type</span><em>email</em></div>
    <div class="mw-feed"><i></i><span>page_screenshot</span><em>done</em></div>
  </div>
</div>
<div class="mw-cmd">
  <div class="mw-cmd-in"><i class="mw-search"></i><span class="mw-typed">no</span><i class="mw-caret"></i></div>
  <div class="mw-cmd-row on"><i class="r1"></i><span>Notes</span><em>Notes on this page, for you and your agents</em></div>
  <div class="mw-cmd-row"><i class="r2"></i><span>Copy Page Notes as Markdown</span><em>Notes</em></div>
  <div class="mw-cmd-row"><i class="r3"></i><span>Notion</span><em>Switch to tab</em></div>
  <div class="mw-cmd-row"><i class="r4"></i><span>notion.so</span><em>Favourite</em></div>
</div>
<div class="mw-pop">
  <div class="mw-pop-h"><i></i><span>Password manager</span></div>
  <div class="mw-pop-r"><i></i><span>Personal</span><em>Fill</em></div>
  <div class="mw-pop-r"><i></i><span>Work</span><em>Fill</em></div>
</div>
<div class="mw-hl" data-part="sidebar"></div>
<div class="mw-hl" data-part="panel"></div>
<div class="mw-hl" data-part="commands"></div>
<div class="mw-hl" data-part="badges"></div>`;

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
function readPausedChoice() {
  try {
    return localStorage.getItem("clips-paused");
  } catch {
    return null;
  }
}
let paused = readPausedChoice() === "1" || (reduced && readPausedChoice() !== "0");

const windows = [...document.querySelectorAll("[data-mw]")];
for (const mw of windows) {
  mw.innerHTML = WINDOW;
  mw.classList.add("mw");
  mw.dataset.scene ||= "sidebar";
  mw.dataset.space ||= "personal";
}

// A scene is a window state plus, for Spaces, a switch partway through.
function show(mw, scene) {
  clearTimeout(mw._spaceTimer);
  mw.dataset.space = "personal";
  // Restart the scene's CSS animations even when it's shown twice in a row.
  mw.dataset.scene = "";
  void mw.offsetWidth;
  mw.dataset.scene = scene;
  if (scene === "spaces") mw._spaceTimer = setTimeout(() => (mw.dataset.space = "work"), 900);
}

// Small windows that cycle on their own: data-cycle="sidebar focus".
const visible = new Set();
const cyclers = windows.filter((mw) => mw.dataset.cycle);
const watcher = new IntersectionObserver((entries) => {
  for (const e of entries) e.isIntersecting ? visible.add(e.target) : visible.delete(e.target);
});
cyclers.forEach((mw) => {
  watcher.observe(mw);
  const scenes = mw.dataset.cycle.split(" ");
  let i = 0;
  show(mw, scenes[0]);
  setInterval(() => {
    if (paused || !visible.has(mw) || document.hidden) return;
    i = (i + 1) % scenes.length;
    show(mw, scenes[i]);
  }, Number(mw.dataset.every || 3400));
});

// The hero: one big window, a row of tabs, a caption that changes with them.
const hero = document.querySelector("[data-hero-window]");
if (hero) {
  const tabs = [...document.querySelectorAll("[data-scene-pick]")];
  const pill = document.querySelector(".t-tabs-pill");
  const caption = document.getElementById("scene-caption");
  const order = tabs.map((t) => t.dataset.scenePick);
  let current = order[0];
  let picked = false;
  let inView = false;
  let timer = 0;

  const movePill = (animate) => {
    const tab = tabs.find((t) => t.dataset.scenePick === current);
    if (!animate) pill.style.transition = "none";
    pill.style.transform = `translateX(${tab.offsetLeft}px)`;
    pill.style.width = `${tab.offsetWidth}px`;
    if (!animate) {
      void pill.offsetWidth;
      pill.style.transition = "";
    }
  };
  const pick = (name, animate = true) => {
    current = name;
    show(hero, name);
    const tab = tabs.find((t) => t.dataset.scenePick === name);
    tabs.forEach((t) => t.setAttribute("aria-pressed", String(t === tab)));
    movePill(animate);
    if (!animate) {
      caption.textContent = tab.dataset.caption;
      return;
    }
    caption.classList.add("is-out");
    setTimeout(() => {
      caption.textContent = tab.dataset.caption;
      caption.classList.remove("is-out");
    }, 150);
  };
  const syncCycle = () => {
    const run = inView && !paused && !picked;
    if (run && !timer) timer = setInterval(() => pick(order[(order.indexOf(current) + 1) % order.length]), 4200);
    else if (!run && timer) {
      clearInterval(timer);
      timer = 0;
    }
  };
  tabs.forEach((t) =>
    t.addEventListener("click", () => {
      picked = true;
      syncCycle();
      pick(t.dataset.scenePick);
    }),
  );
  new IntersectionObserver(([e]) => {
    inView = e.isIntersecting;
    syncCycle();
  }, { threshold: 0.4 }).observe(hero);
  addEventListener("resize", () => movePill(false));
  pick(current, false);
  hero.closest("[hidden]")?.removeAttribute("hidden");
  window._syncHero = syncCycle;
}

// Pause and play, shared with the iPhone page's clips.
const motion = document.getElementById("motion");
if (motion) {
  const sync = () => {
    motion.setAttribute("aria-pressed", String(paused));
    motion.querySelector("span").textContent = paused ? "Play motion" : "Pause motion";
    document.documentElement.classList.toggle("is-still", paused);
    window._syncHero?.();
  };
  motion.addEventListener("click", () => {
    paused = !paused;
    try {
      localStorage.setItem("clips-paused", paused ? "1" : "0");
    } catch {}
    sync();
  });
  sync();
} else {
  document.documentElement.classList.toggle("is-still", paused);
}

// The developer page: pointing at a manifest key, or its legend entry, lights up where it lands.
const anatomy = document.querySelector("[data-anatomy]");
if (anatomy) {
  const keys = [...document.querySelectorAll("[data-points]")];
  const scenes = { sidebar: "sidebar", badges: "sidebar", panel: "panel", commands: "command", agentTools: "agent" };
  const light = (part) => {
    if (anatomy.dataset.lit === part) return;
    anatomy.dataset.lit = part || "";
    show(anatomy, scenes[part] || "sidebar");
    keys.forEach((k) => k.classList.toggle("is-lit", k.dataset.points === part));
  };
  for (const k of keys) {
    k.addEventListener("mouseenter", () => light(k.dataset.points));
    k.addEventListener("focus", () => light(k.dataset.points));
    k.addEventListener("click", () => light(k.dataset.points));
  }
  // Until someone points, walk through them.
  let i = 0;
  let touched = false;
  keys.forEach((k) => k.addEventListener("pointerenter", () => (touched = true)));
  const parts = [...new Set(keys.map((k) => k.dataset.points))];
  light(parts[0]);
  setInterval(() => {
    if (touched || paused) return;
    i = (i + 1) % parts.length;
    light(parts[i]);
  }, 2400);
}
