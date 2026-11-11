// The Mac pages: a drawn model of Browsa's window, standing in for footage. Sizes come from the
// app (Mac/Sources): one unit is one point of a 1280 × 800 window, so the 260pt sidebar, 6pt page
// inset, 9pt page corners, 320pt panel and 640pt command bar are the app's own numbers.
// Every element with `data-mw` gets a window. What it shows is pure CSS on `data-scene` and
// `data-space`; this file only builds the markup and moves between scenes.

import { ICON, FAV, travelBlog, devDocs, supper, library } from "/desktop-sites.js";

const tab = (fav, title, page = "", extra = "") => `<div class="mw-tab"${page ? ` data-p="${page}"` : ""}>${fav}<span>${title}</span>${extra}</div>`;

// The agent demo's steps, in the Activity card's words (Mac/Sources/Agents/AgentsUI.swift, AgentWords).
const STEPS = ["Opened browsa.app/demo", "Read ‘Supper’", "Typed ‘6’ into guests", "Clicked ‘Add to menu’", "Clicked ‘Swap’", "Clicked ‘Saturday 5–7 pm’", "Left a note: “Dinner for 6, $28.20 all in…”"];

const WINDOW = `
<div class="mw-side">
  <div class="mw-top">
    <span class="mw-lights"><i></i><i></i><i></i></span>
    <span class="mw-ib">${ICON.sidebarLeft}</span><span class="mw-ib">${ICON.back}</span><span class="mw-ib dim">${ICON.forward}</span><span class="mw-ib">${ICON.reload}</span>
    <span class="mw-ib end">${ICON.sidebarRight}</span>
  </div>
  <div class="mw-drive">
    <i class="mw-drive-ic">${ICON.rays}<i></i></i>
    <span><b>Claude Code</b><span class="mw-drive-t">${STEPS.map((t, i) => `<em data-s="${i}">${t}</em>`).join("")}</span></span>
    <i class="mw-drive-stop">${ICON.stop}</i>
  </div>
  <div class="mw-addr">
    <span class="mw-lock">${ICON.lock}</span>
    <span class="mw-host"><span data-p="travel">wanderandsalt.com</span><span data-p="docs">docs.tern.dev</span><span data-p="supper">browsa.app/demo</span><span data-p="library">Library</span></span>
    <span class="mw-exts"><img class="x-1p" src="/media/ext/1password.png" alt="" width="16" height="16"></span>
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
    ${tab(FAV.supper, "Supper · Plan a dinner", "supper", '<b class="mw-pins">3</b>')}
    ${tab(FAV.books, "Library", "library")}
    ${tab(FAV.rail, "Oslo to Bodø · Nordic Rail")}
  </div>
  <div class="mw-list sp-w">
    <div class="mw-spacehead">${ICON.briefcase}Work</div>
    ${tab(FAV.tern, "Webhooks · Tern Docs", "docs")}
    ${tab(FAV.nw, "Northwind · Checkout", "", '<b class="mw-badge">3</b>')}
    <div class="mw-today"></div>
    <div class="mw-newtab">${ICON.plus}New Tab</div>
    ${tab(FAV.forge, "Bigger pay button #212")}
    ${tab(FAV.pine, "Standup notes")}
  </div>
  <div class="mw-list sp-a">
    <div class="mw-spacehead">${ICON.rays}Agent</div>
    ${tab(FAV.supper, "Supper · Plan a dinner", "supper")}
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
    <span class="mw-dots"><i class="d-p">${ICON.house}</i><i class="d-w">${ICON.briefcase}</i><i class="d-a">${ICON.rays}</i></span>
    <span class="mw-ib">${ICON.plus}</span>
  </div>
</div>
<div class="mw-page">
  <div class="mw-site" data-p="travel">${travelBlog}</div>
  <div class="mw-site" data-p="docs">${devDocs}</div>
  <div class="mw-site" data-p="supper">${supper}</div>
  <div class="mw-site" data-p="library">${library}</div>
</div>
<div class="mw-panel">
  <div class="mw-panel-h">
    <b class="t-notes">Notes</b><b class="t-agents">Agents</b>
    <span class="mw-rail"><i class="r-notes">${ICON.bubble}</i><i class="r-agents">${ICON.rays}</i><i>${ICON.download}</i><i>${ICON.radar}</i></span>
    <span class="mw-ib">${ICON.sidebarRight}</span>
  </div>
  <div class="mw-pane notes">
    <div class="mw-ntools">
      <span class="mw-comment">${ICON.plusBubble}<b class="c-off">Comment</b><b class="c-on">Picking</b></span>
      <span class="mw-scope"><b class="on">This Page</b><b>This Site</b></span>
      <i class="mw-more">${ICON.ellipsis}</i>
    </div>
    <div class="mw-note n1">
      <p class="who"><i class="pin">1</i><b class="ai">${ICON.rays}Claude Code</b><em>4m</em></p>
      <p class="quote">Your menu</p>
      <p>Dinner for 6, $28.20 all in, with a vegetarian main. Delivery Saturday 5–7 pm. Press Place order when you’re happy.</p>
    </div>
    <div class="mw-note n2">
      <p class="who"><i class="pin">2</i><b class="ai">${ICON.rays}Claude Code</b><em>4m</em></p>
      <p class="sel">${ICON.scope}#ingredient-parmesan</p>
      <p>Swapped the Parmesan for a vegetarian hard cheese: traditional Parmesan is made with animal rennet.</p>
      <div class="reply"><p class="who"><b>You</b><em>2m</em></p><p>Good catch, thank you.</p></div>
    </div>
    <div class="mw-note n3">
      <p class="who"><i class="pin">3</i><b>You</b><em>now</em></p>
      <p class="sel">${ICON.scope}Place order button</p>
      <p class="typed">Add a dessert before we order. Something light.</p>
    </div>
  </div>
  <div class="mw-pane agents">
    <div class="mw-astat">
      <i class="dot"></i>
      <span><b>Driving</b><em>${ICON.rays}Claude Code</em></span>
      <i class="mw-more">${ICON.ellipsis}</i>
      <span class="mw-stop">Stop</span>
    </div>
    <p class="mw-acap">Activity</p>
    <div class="mw-run">
      <p class="mw-run-h">${ICON.rays}<b>Claude Code</b><em>now</em><i>${ICON.chevronDown}</i></p>
      ${STEPS.map((t, i) => `<p class="mw-step" data-s="${i}"><i>${ICON.tick}</i><span>${t}</span></p>`).join("")}
    </div>
  </div>
</div>
<div class="mw-cmd">
  <div class="mw-cmd-in">${ICON.command}<span class="mw-ph">Open a tool or run a command</span></div>
  <div class="mw-strip">
    <span><i>${ICON.bubble}</i>Notes</span><span><i>${ICON.rays}</i>Agents</span><span><i>${ICON.download}</i>Downloads</span><span><i>${ICON.radar}</i>Radar</span><span class="get-more"><i>${ICON.plus}</i>Get More</span>
  </div>
  <div class="mw-cmd-rows">
    <p class="mw-cmd-sect">Commands</p>
    <div class="mw-row">${ICON.sidebarRight}<span><b>Show Panel</b></span><kbd>⌥⌘S</kbd></div>
    <div class="mw-row">${ICON.rays}<span><b>Go to Agent Space</b></span></div>
    <div class="mw-row">${ICON.undo}<span><b>Reopen Closed Tab</b><em>Slow-roast tomatoes</em></span><kbd>⇧⌘T</kbd></div>
    <div class="mw-row">${ICON.stackPlus}<span><b>New Space</b></span></div>
    <div class="mw-row">${ICON.sidebarLeft}<span><b>Hide Sidebar</b></span><kbd>⌘S</kbd></div>
    <div class="mw-row">${ICON.gear}<span><b>Settings</b></span><kbd>⌘,</kbd></div>
  </div>
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

// Each scene's space and page.
const SPACE = { sidebar: "personal", focus: "personal", command: "personal", spaces: "work", work: "work", notes: "personal", extensions: "personal", agent: "agent" };
const PAGE = { spaces: "docs", work: "docs", notes: "supper", extensions: "library", agent: "supper" };
// Which Supper capture each scene opens on; the agent moves through 0 to 4 as it works.
const SHOT = { notes: 4, agent: 0 };
// The agent's timeline: when each step lands (ms), and the capture it leaves on the page.
const AGENT_AT = [300, 1300, 2500, 3700, 4900, 6100];
const AGENT_SHOT = [0, 1, 2, 3, 4, 4];

const windows = [...document.querySelectorAll("[data-mw]")];
windows.forEach((mw, n) => {
  // Every window draws the same fjord, so its gradient ids get a suffix to stay unique.
  mw.innerHTML = WINDOW.replace(/id="(\w+)"/g, `id="$1-${n}"`).replace(/url\(#(\w+)\)/g, `url(#$1-${n})`);
  mw.classList.add("mw");
  mw.dataset.scene ||= "sidebar";
  mw.dataset.space ||= SPACE[mw.dataset.scene];
  mw.dataset.page ||= PAGE[mw.dataset.scene] || "travel";
});

// Marks the agent's progress: the step it's on, and which Activity rows have landed.
function agentStep(mw, n) {
  mw.dataset.step = n;
  const done = n === "" ? -1 : n === "done" ? STEPS.length - 1 : n;
  mw.querySelectorAll(".mw-step").forEach((r, i) => r.classList.toggle("on", i <= done));
  mw.querySelectorAll(".mw-drive-t em").forEach((e, i) => e.classList.toggle("on", i === Math.max(done, 0)));
}

function show(mw, scene) {
  clearInterval(mw._timer);
  // Restart the scene's CSS animations even when it's shown twice in a row.
  mw.dataset.scene = "";
  void mw.offsetWidth;
  mw.dataset.scene = scene;
  mw.dataset.space = SPACE[scene] || "personal";
  mw.dataset.page = PAGE[scene] || "travel";
  mw.dataset.shot = SHOT[scene] ?? 0;
  agentStep(mw, "");
  if (scene !== "agent") return;
  // The agent works through its steps on a clock that stops while motion is paused.
  let t = 0;
  let n = 0;
  mw._timer = setInterval(() => {
    if (paused) return;
    t += 100;
    while (n < AGENT_AT.length && t >= AGENT_AT[n]) {
      agentStep(mw, n);
      // The click lands, then the page answers.
      const shot = AGENT_SHOT[n];
      setTimeout(() => (mw.dataset.shot = shot), n ? 420 : 0);
      n++;
    }
    if (n === AGENT_AT.length && t >= AGENT_AT[n - 1] + 900) {
      agentStep(mw, "done");
      clearInterval(mw._timer);
    }
  }, 100);
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
const HOLD = { notes: 6400, extensions: 5600, agent: 9400 };
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
    // Each scene stays long enough to play out; the agent's takes longest.
    if (run && !timer) timer = setTimeout(() => {
      timer = 0;
      pick(order[(order.indexOf(current) + 1) % order.length]);
      syncCycle();
    }, HOLD[current] || 5200);
    else if (!run && timer) {
      clearTimeout(timer);
      timer = 0;
    }
  };
  tabs.forEach((t) =>
    t.addEventListener("click", () => {
      picked = true;
      clearTimeout(timer);
      timer = 0;
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
  window._syncBento?.();
};
motion?.addEventListener("click", () => {
  paused = !paused;
  try {
    localStorage.setItem("clips-paused", paused ? "1" : "0");
  } catch {}
  syncMotion();
});
syncMotion();

// The little things: the bento's loops start once it's in view, and the shortcut keys take turns.
const bento = document.querySelector("[data-bento]");
if (bento) {
  // Browsa's own preset, from Mac/Sources/State/Shortcuts.swift. Modifiers in the Mac's order: ⌃ ⌥ ⇧ ⌘.
  const KEYS = [
    ["⌘K", "Commands and tools"],
    ["⌘T", "New tab"],
    ["⌘S", "Hide the sidebar"],
    ["⌘D", "Pin tab"],
    ["⇧⌘D", "Add to Favourites"],
    ["⌃1", "First space"],
    ["⇧⌘R", "Reader"],
    ["⇧⌘J", "Downloads"],
    ["⇧⌘T", "Reopen closed tab"],
    ["⌥⌘↓", "Next tab"],
    ["⇧⌘K", "Clear Today"],
    ["⌘Y", "Archived tabs"],
    ["⇧⌘N", "Private tab"],
    ["⇧⌘M", "Notes"],
  ];
  const caps = bento.querySelector(".v-caps");
  const act = bento.querySelector(".v-act");
  const cheat = bento.querySelector(".v-cheat");
  cheat.innerHTML = KEYS.map(([k, name]) => `<span><kbd>${k}</kbd>${name}</span>`).join("");
  const chips = [...cheat.children];
  let k = 0;
  let inView = false;
  let timer = 0;
  const showKey = (n) => {
    k = n;
    chips.forEach((c, i) => c.classList.toggle("on", i === n));
    const [combo, name] = KEYS[n];
    caps.innerHTML = [...combo].map((c) => `<kbd class="cap is-new">${c}</kbd>`).join("");
    act.classList.add("is-out");
    setTimeout(() => {
      act.textContent = name;
      act.classList.remove("is-out");
    }, 150);
    // Press the keys down together, a beat after they land.
    setTimeout(() => caps.querySelectorAll(".cap").forEach((c) => c.classList.replace("is-new", "is-down")), 520);
    setTimeout(() => caps.querySelectorAll(".cap").forEach((c) => c.classList.remove("is-down")), 760);
  };
  chips.forEach((c, i) => c.classList.toggle("on", i === 0));
  const sync = () => {
    const run = inView && !paused && !document.hidden;
    if (run) bento.classList.add("is-on");
    if (run && !timer) timer = setInterval(() => showKey((k + 1) % KEYS.length), 2000);
    else if (!run && timer) {
      clearInterval(timer);
      timer = 0;
    }
  };
  new IntersectionObserver(([e]) => {
    inView = e.isIntersecting;
    sync();
  }, { threshold: 0.15 }).observe(bento);
  document.addEventListener("visibilitychange", sync);
  window._syncBento = sync;
}

// The developer page: a picker under the window, like the Mac page's hero. Each part outlines
// where it lands, and lights its key in the manifest; pointing at a key picks it too.
const anatomy = document.querySelector("[data-anatomy]");
if (anatomy) {
  const tabs = [...document.querySelectorAll(".t-tab[data-points]")];
  const keys = [...document.querySelectorAll(".code [data-points]")];
  const pill = document.querySelector(".anatomy .t-tabs-pill");
  const caption = document.querySelector(".anatomy-caption");
  const hl = anatomy.querySelector(".mw-hl");
  const SCENES = { sidebar: "work", badges: "work", panel: "notes", commands: "command", agentTools: "agent" };
  const TARGET = { sidebar: ".mw-sect", badges: ".sp-w .mw-badge", panel: ".mw-panel", commands: ".mw-cmd-rows", agentTools: ".mw-pane.agents" };
  let lit = "";
  const outline = () => {
    const el = anatomy.querySelector(TARGET[lit]);
    if (!el) return;
    const a = anatomy.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    Object.assign(hl.style, { left: `${r.left - a.left}px`, top: `${r.top - a.top}px`, width: `${r.width}px`, height: `${r.height}px` });
  };
  const movePill = (animate) => {
    const t = tabs.find((t) => t.dataset.points === lit);
    if (!t) return;
    if (!animate) pill.style.transition = "none";
    pill.style.transform = `translateX(${t.offsetLeft}px)`;
    pill.style.width = `${t.offsetWidth}px`;
    if (!animate) {
      void pill.offsetWidth;
      pill.style.transition = "";
    }
  };
  const light = (part, animate = true) => {
    if (lit === part) return;
    lit = part;
    anatomy.dataset.lit = part;
    hl.classList.remove("on");
    show(anatomy, SCENES[part]);
    keys.forEach((k) => k.classList.toggle("is-lit", k.dataset.points === part));
    const t = tabs.find((t) => t.dataset.points === part);
    tabs.forEach((x) => x.setAttribute("aria-pressed", String(x === t)));
    movePill(animate);
    caption.classList.add("is-out");
    setTimeout(() => {
      caption.textContent = t.dataset.caption;
      caption.classList.remove("is-out");
    }, animate ? 150 : 0);
    setTimeout(() => {
      outline();
      hl.classList.add("on");
    }, reduced ? 0 : 520);
  };
  // Until someone picks, walk through them.
  let touched = false;
  for (const el of [...tabs, ...keys]) {
    el.addEventListener("click", () => ((touched = true), light(el.dataset.points)));
    el.addEventListener("focus", () => light(el.dataset.points));
  }
  for (const k of keys) k.addEventListener("mouseenter", () => ((touched = true), light(k.dataset.points)));
  addEventListener("resize", () => (outline(), movePill(false)));
  const parts = tabs.map((t) => t.dataset.points);
  let i = 0;
  light(parts[0], false);
  setInterval(() => {
    if (touched || paused) return;
    i = (i + 1) % parts.length;
    light(parts[i]);
  }, 3200);
}
