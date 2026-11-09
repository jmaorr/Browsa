// The Mac pages: a drawn model of Browsa's window, standing in for footage. Sizes come from the
// app (Mac/Sources): one unit is one point of a 1280 × 800 window, so the 260pt sidebar, 6pt page
// inset, 9pt page corners, 320pt panel and 640pt command bar are the app's own numbers.
// Every element with `data-mw` gets a window. What it shows is pure CSS on `data-scene` and
// `data-space`; this file only builds the markup and moves between scenes.

import { ICON, FAV, travelBlog, devDocs, shop } from "/desktop-sites.js";

const tab = (fav, title, page = "", extra = "") => `<div class="mw-tab"${page ? ` data-p="${page}"` : ""}>${fav}<span>${title}</span>${extra}</div>`;

const WINDOW = `
<div class="mw-side">
  <div class="mw-top">
    <span class="mw-lights"><i></i><i></i><i></i></span>
    <span class="mw-ib">${ICON.sidebarLeft}</span><span class="mw-ib">${ICON.back}</span><span class="mw-ib dim">${ICON.forward}</span><span class="mw-ib">${ICON.reload}</span>
    <span class="mw-ib end">${ICON.sidebarRight}</span>
  </div>
  <div class="mw-addr">
    <span class="mw-lock">${ICON.lock}</span>
    <span class="mw-host"><span data-p="travel">wanderandsalt.com</span><span data-p="docs">docs.tern.dev</span><span data-p="shop">localhost:3000</span></span>
    <span class="mw-exts"><i class="x-key">${ICON.key}</i><i class="x-shield">${ICON.shield}</i><i class="x-moon">${ICON.moon}</i></span>
  </div>
  <div class="mw-favs">
    <span>${FAV.post}</span><span>${FAV.pine}</span><span>${FAV.forge}</span><span>${FAV.tern}</span>
  </div>
  <div class="mw-list sp-p">
    <div class="mw-spacehead">${ICON.house}Personal</div>
    ${tab(FAV.ws, "Chasing light in Lofoten", "travel")}
    ${tab(FAV.kitchen, "Slow-roast tomatoes")}
    <div class="mw-today"></div>
    <div class="mw-newtab">${ICON.plus}New Tab</div>
    ${tab(FAV.rail, "Oslo to Bodø · Nordic Rail")}
    ${tab(FAV.ws, "Hamnøy cabins · Wander & Salt")}
  </div>
  <div class="mw-list sp-w">
    <div class="mw-spacehead">${ICON.briefcase}Work</div>
    ${tab(FAV.tern, "Webhooks · Tern Docs", "docs")}
    ${tab(FAV.nw, "Northwind · Checkout", "shop", '<b class="mw-badge">3</b>')}
    <div class="mw-today"></div>
    <div class="mw-newtab">${ICON.plus}New Tab</div>
    ${tab(FAV.forge, "Bigger pay button #212")}
    ${tab(FAV.pine, "Standup notes")}
  </div>
  <div class="mw-list sp-a">
    <div class="mw-spacehead">${ICON.sparkles}Agent</div>
    ${tab(FAV.nw, "Northwind · Checkout", "shop")}
    <div class="mw-today"></div>
    <div class="mw-newtab">${ICON.plus}New Tab</div>
  </div>
  <div class="mw-sect">
    <div class="mw-sect-h">${ICON.radar}DEV SERVERS${ICON.chevronDown}</div>
    <div class="mw-sect-r"><i></i><span>checkout-web</span><em>3000</em></div>
    <div class="mw-sect-r"><i></i><span>feat/pay-button</span><em>3001</em></div>
    <div class="mw-sect-r off"><i></i><span>api</span><em>8080</em></div>
  </div>
  <div class="mw-bottom">
    <span class="mw-ib">${ICON.download}</span>
    <span class="mw-dots"><i class="d-p">${ICON.house}</i><i class="d-w">${ICON.briefcase}</i><i class="d-a">${ICON.sparkles}</i></span>
    <span class="mw-ib">${ICON.plus}</span>
  </div>
</div>
<div class="mw-page">
  <div class="mw-site" data-p="travel">${travelBlog}</div>
  <div class="mw-site" data-p="docs">${devDocs}</div>
  <div class="mw-site" data-p="shop">${shop}</div>
  <i class="mw-cursor">${ICON.cursor}</i>
</div>
<div class="mw-panel">
  <div class="mw-panel-h">
    <b class="t-notes">Notes</b><b class="t-agents">Agents</b>
    <span class="mw-rail"><i class="r-notes">${ICON.bubble}</i><i class="r-agents">${ICON.sparkles}</i><i class="r-radar">${ICON.radar}</i></span>
    <span class="mw-ib">${ICON.sidebarRight}</span>
  </div>
  <div class="mw-pane notes">
    <div class="mw-note">
      <p class="who"><b>You</b><em>12 min</em></p>
      <p class="quote">Pay $329</p>
      <p>The pay button is hard to spot on small screens.</p>
      <div class="reply"><p class="who ai">${ICON.sparkles}<b>Claude Code</b></p><p>Made it full width with more contrast on feat/pay-button. Have a look on :3001.</p></div>
    </div>
    <div class="mw-note">
      <p class="who"><b>You</b><em>8 min</em></p>
      <p>Card field should say which cards we take.</p>
    </div>
    <div class="mw-note done">
      <p class="who"><b>You</b><span class="ok">${ICON.check}Resolved</span></p>
      <p>Typo in "Order sumary".</p>
    </div>
  </div>
  <div class="mw-pane agents">
    <div class="mw-agent-h"><span>${ICON.sparkles}<b>Claude Code</b><em>Working on localhost:3000</em></span><span class="mw-stop">${ICON.stop}Stop</span></div>
    <div class="mw-feed"><code>tab_open</code><span>localhost:3000/checkout</span></div>
    <div class="mw-feed"><code>page_read</code><span>Checkout · 3 fields</span></div>
    <div class="mw-feed"><code>page_type</code><span>Email</span></div>
    <div class="mw-feed"><code>page_type</code><span>Name on card</span></div>
    <div class="mw-feed"><code>page_click</code><span>Pay $329</span></div>
    <div class="mw-feed"><code>page_screenshot</code><span>Saved</span></div>
  </div>
</div>
<div class="mw-cmd">
  <div class="mw-cmd-in">${ICON.searchPlus}<span class="mw-typed">lofo</span><span class="mw-inline">ten in winter</span></div>
  <div class="mw-cmd-rows">
    <div class="mw-row on">${FAV.ws}<span><b>Chasing light in Lofoten</b><em>wanderandsalt.com</em></span><u>Switch to Tab</u>${ICON.ret}</div>
    <div class="mw-row">${ICON.search}<span><b>lofoten northern lights forecast</b></span></div>
    <div class="mw-row">${ICON.search}<span><b>lofoten winter ferry bodø</b></span></div>
    <div class="mw-row">${ICON.book}<span><b>Lofoten</b><em>Wikipedia</em></span></div>
    <div class="mw-row">${ICON.bubble}<span><b>Notes</b><em>Notes on this page, for you and your agents</em></span><u>Tool</u></div>
  </div>
</div>
<div class="mw-pop">
  <div class="mw-pop-h">${ICON.key}<b>Passwords</b></div>
  <div class="mw-pop-r on"><i>A</i><span><b>ada@northwind.dev</b><em>localhost</em></span><u>Fill</u></div>
  <div class="mw-pop-r"><i>T</i><span><b>test-buyer</b><em>localhost</em></span><u>Fill</u></div>
</div>
<div class="mw-hl"></div>`;

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
function readPausedChoice() {
  try {
    return localStorage.getItem("clips-paused");
  } catch {
    return null;
  }
}
let paused = readPausedChoice() === "1" || (reduced && readPausedChoice() !== "0");

// Each scene's space, unless the scene changes it partway through.
const SPACE = { sidebar: "personal", focus: "personal", command: "personal", spaces: "personal", work: "work", panel: "work", extensions: "work", agent: "agent" };
// And the page it shows.
const PAGE = { work: "docs", panel: "shop", extensions: "shop", agent: "shop" };

const windows = [...document.querySelectorAll("[data-mw]")];
windows.forEach((mw, n) => {
  // Every window draws the same fjord, so its gradient ids get a suffix to stay unique.
  mw.innerHTML = WINDOW.replace(/id="(\w+)"/g, `id="$1-${n}"`).replace(/url\(#(\w+)\)/g, `url(#$1-${n})`);
  mw.classList.add("mw");
  mw.dataset.scene ||= "sidebar";
  mw.dataset.space ||= SPACE[mw.dataset.scene];
  mw.dataset.page ||= PAGE[mw.dataset.scene] || "travel";
});

function show(mw, scene) {
  clearTimeout(mw._timer);
  // Restart the scene's CSS animations even when it's shown twice in a row.
  mw.dataset.scene = "";
  void mw.offsetWidth;
  mw.dataset.scene = scene;
  mw.dataset.space = SPACE[scene] || "personal";
  mw.dataset.page = PAGE[scene] || "travel";
  if (scene === "spaces") {
    mw._timer = setTimeout(() => {
      mw.dataset.space = "work";
      mw.dataset.page = "docs";
    }, 1100);
  }
}

// Small windows that cycle on their own: data-cycle="sidebar focus".
const visible = new Set();
const watcher = new IntersectionObserver((entries) => {
  for (const e of entries) e.isIntersecting ? visible.add(e.target) : visible.delete(e.target);
});
windows
  .filter((mw) => mw.dataset.cycle)
  .forEach((mw) => {
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
windows.filter((mw) => !mw.dataset.cycle && !mw.hasAttribute("data-hero-window")).forEach((mw) => show(mw, mw.dataset.scene));

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
    const t = tabs.find((t) => t.dataset.scenePick === current);
    if (!animate) pill.style.transition = "none";
    pill.style.transform = `translateX(${t.offsetLeft}px)`;
    pill.style.width = `${t.offsetWidth}px`;
    if (!animate) {
      void pill.offsetWidth;
      pill.style.transition = "";
    }
  };
  const pick = (name, animate = true) => {
    current = name;
    show(hero, name);
    const t = tabs.find((t) => t.dataset.scenePick === name);
    tabs.forEach((x) => x.setAttribute("aria-pressed", String(x === t)));
    movePill(animate);
    if (!animate) {
      caption.textContent = t.dataset.caption;
      return;
    }
    caption.classList.add("is-out");
    setTimeout(() => {
      caption.textContent = t.dataset.caption;
      caption.classList.remove("is-out");
    }, 150);
  };
  const syncCycle = () => {
    const run = inView && !paused && !picked;
    if (run && !timer) timer = setInterval(() => pick(order[(order.indexOf(current) + 1) % order.length]), 5200);
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
  window._syncHero = syncCycle;
}

// Pause and play, shared with the iPhone page's clips.
const motion = document.getElementById("motion");
const syncMotion = () => {
  document.documentElement.classList.toggle("is-still", paused);
  if (!motion) return;
  motion.setAttribute("aria-pressed", String(paused));
  motion.querySelector("span").textContent = paused ? "Play motion" : "Pause motion";
  window._syncHero?.();
};
motion?.addEventListener("click", () => {
  paused = !paused;
  try {
    localStorage.setItem("clips-paused", paused ? "1" : "0");
  } catch {}
  syncMotion();
});
syncMotion();

// The developer page: pointing at a manifest key, or its legend entry, outlines where it lands.
const anatomy = document.querySelector("[data-anatomy]");
if (anatomy) {
  const keys = [...document.querySelectorAll("[data-points]")];
  const hl = anatomy.querySelector(".mw-hl");
  const SCENES = { sidebar: "work", badges: "work", panel: "panel", commands: "command", agentTools: "agent" };
  const TARGET = { sidebar: ".mw-sect", badges: ".sp-w .mw-badge", panel: ".mw-panel", commands: ".mw-cmd-rows", agentTools: ".mw-pane.agents" };
  let lit = "";
  const outline = () => {
    const el = anatomy.querySelector(TARGET[lit]);
    if (!el) return;
    const a = anatomy.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    Object.assign(hl.style, { left: `${r.left - a.left}px`, top: `${r.top - a.top}px`, width: `${r.width}px`, height: `${r.height}px` });
  };
  const light = (part) => {
    if (lit === part) return;
    lit = part;
    anatomy.dataset.lit = part;
    hl.classList.remove("on");
    show(anatomy, SCENES[part]);
    keys.forEach((k) => k.classList.toggle("is-lit", k.dataset.points === part));
    setTimeout(() => {
      outline();
      hl.classList.add("on");
    }, reduced ? 0 : 520);
  };
  for (const k of keys) {
    k.addEventListener("mouseenter", () => light(k.dataset.points));
    k.addEventListener("focus", () => light(k.dataset.points));
    k.addEventListener("click", () => light(k.dataset.points));
  }
  addEventListener("resize", outline);
  // Until someone points, walk through them.
  let touched = false;
  keys.forEach((k) => k.addEventListener("pointerenter", () => (touched = true)));
  const parts = [...new Set(keys.map((k) => k.dataset.points))];
  let i = 0;
  light(parts[0]);
  setInterval(() => {
    if (touched || paused) return;
    i = (i + 1) % parts.length;
    light(parts[i]);
  }, 2800);
}
