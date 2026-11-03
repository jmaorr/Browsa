import { generate } from "/vendor/transitions/ui-generation.js";

const clips = [...document.querySelectorAll("video[data-loop]")];
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const motionButton = document.getElementById("motion");
const visible = new Set();
const heroClips = new Set(document.querySelectorAll(".stage video"));
let heroDrawing = false;

function readPausedChoice() {
  try {
    return localStorage.getItem("clips-paused");
  } catch {
    return null;
  }
}
let paused = readPausedChoice() === "1" || (reduced && readPausedChoice() !== "0");

function sync() {
  syncCycle();
  for (const clip of clips) {
    const held = heroDrawing && heroClips.has(clip);
    if (!paused && !held && visible.has(clip) && !clip.closest("[hidden]")) clip.play().catch(() => {});
    else clip.pause();
  }
  motionButton.setAttribute("aria-pressed", String(paused));
  motionButton.querySelector("span").textContent = paused ? "Play clips" : "Pause clips";
}

// Only clips on screen play, so the page stays light on battery and data.
const watcher = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) visible.add(entry.target);
      else visible.delete(entry.target);
    }
    sync();
  },
  { rootMargin: "120px 0px" },
);
clips.forEach((clip) => watcher.observe(clip));

motionButton.addEventListener("click", () => {
  paused = !paused;
  try {
    localStorage.setItem("clips-paused", paused ? "1" : "0");
  } catch {}
  sync();
});

const stage = document.querySelector(".stage");
const postureButtons = document.querySelectorAll("[data-set-posture]");
let heroRun = null;
function setPosture(posture) {
  if (heroRun) heroRun.cancel();
  stage.dataset.posture = posture;
  document.getElementById("posture-open").hidden = posture !== "open";
  document.getElementById("posture-closed").hidden = posture !== "closed";
  postureButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.setPosture === posture)));
  sync();
}
postureButtons.forEach((b) =>
  b.addEventListener("click", () => {
    stage.classList.add("is-toggled");
    setPosture(b.dataset.setPosture);
  }),
);
// The layouts. Every position is measured off stills of the real app, in pixels of the 900-wide
// open screen, so each piece lands where it does on the device.
const hidden = { o: 0 };
const dark = { bg: "#08090a", fg: "#f2f2f2", chip: "rgb(255 255 255 / .1)", edge: "rgb(255 255 255 / .1)" };
const gutter = {
  time: { x: 830, y: 28, w: 50, h: 20 },
  ring: { x: 834, y: 52, w: 42, h: 42 },
  cam: { ...hidden, x: 838, y: -40, w: 34, h: 34 },
  navbg: { x: 832, y: 117, w: 46, h: 145 },
  back: { x: 843, y: 130, w: 24, h: 24 },
  fwd: { x: 843, y: 178, w: 24, h: 24 },
  more: { x: 843, y: 226, w: 24, h: 24 },
  stackbg: { x: 832, y: 515, w: 46, h: 96 },
  plus: { x: 842, y: 527, w: 26, h: 26 },
  toggle: { x: 842, y: 575, w: 26, h: 26 },
  tabs: { ...hidden, x: 842, y: 575, w: 26, h: 26 },
};
const portraitBars = {
  topbar: { x: 0, y: 0, w: 633, h: 62 },
  time: { x: 500, y: 21, w: 50, h: 20 },
  ring: { x: 560, y: 13, w: 36, h: 36 },
  cam: { ...hidden, x: 300, y: -40, w: 34, h: 34 },
  navbg: { x: 16, y: 11, w: 92, h: 40 },
  back: { x: 28, y: 19, w: 24, h: 24 },
  fwd: { x: 72, y: 19, w: 24, h: 24 },
  more: { x: 455, y: 19, w: 24, h: 24 },
  stackbg: { x: 572, y: 846, w: 42, h: 42 },
  plus: { x: 580, y: 854, w: 26, h: 26 },
  toggle: { x: 26, y: 854, w: 26, h: 26 },
  tabs: { ...hidden, x: 26, y: 854, w: 26, h: 26 },
  pill: { x: 66, y: 846, w: 494, h: 42 },
};
const LAYOUTS = {
  sidebar: {
    caption: "The sidebar pushes the page aside, and the page becomes a card.",
    device: { w: 918, h: 651, r: 43, tl: 43 },
    colors: { bg: "#fdedde", fg: "#1b1a18", chip: "rgb(255 255 255 / .35)", edge: "rgb(0 0 0 / .08)" },
    page: { x: 272, y: 8, w: 546, h: 617, r: 13, narrow: 0 },
    parts: {
      ...gutter,
      sidebar: { x: 0, y: 0, w: 270, h: 633 },
      pill: { ...hidden, x: 282, y: 570, w: 300, h: 42 },
      topbar: { ...hidden, x: 0, y: 0, w: 900, h: 0 },
      scrim: { ...hidden, x: 272, y: 8, w: 546, h: 617 },
    },
  },
  open: {
    caption: "The page fills the screen, and the gutter stays beside it.",
    device: { w: 918, h: 651, r: 43, tl: 43 },
    colors: dark,
    page: { x: 0, y: 0, w: 818, h: 633, r: 0, narrow: 0 },
    parts: {
      ...gutter,
      sidebar: { ...hidden, x: -290, y: 0, w: 270, h: 633 },
      pill: { x: 260, y: 572, w: 300, h: 42 },
      topbar: { ...hidden, x: 0, y: 0, w: 900, h: 0 },
      scrim: { ...hidden, x: 0, y: 0, w: 818, h: 633 },
    },
  },
  portrait: {
    caption: "The gutter's controls move to a bar along the top.",
    device: { w: 651, h: 918, r: 43, tl: 43 },
    colors: dark,
    page: { x: 0, y: 62, w: 633, h: 838, r: 0, narrow: 0 },
    parts: {
      ...portraitBars,
      sidebar: { ...hidden, x: -290, y: 0, w: 270, h: 900 },
      scrim: { ...hidden, x: 0, y: 0, w: 633, h: 900 },
    },
  },
  overlay: {
    caption: "In portrait, the sidebar slides over the page instead of pushing it.",
    device: { w: 651, h: 918, r: 43, tl: 43 },
    colors: dark,
    page: { x: 0, y: 62, w: 633, h: 838, r: 0, narrow: 0 },
    parts: {
      ...portraitBars,
      sidebar: { x: 0, y: 0, w: 270, h: 900 },
      scrim: { x: 0, y: 0, w: 633, h: 900 },
    },
  },
  closed: {
    caption: "A phone layout, with the address pill under your thumb and the controls in the gutter.",
    device: { w: 457, h: 658, r: 48, tl: 11 },
    colors: dark,
    page: { x: 0, y: 0, w: 360, h: 642, r: 0, narrow: 1 },
    parts: {
      time: { x: 369, y: 77, w: 50, h: 20 },
      ring: { x: 373, y: 101, w: 42, h: 42 },
      cam: { x: 377, y: 27, w: 34, h: 34 },
      navbg: { x: 372, y: 165, w: 44, h: 142 },
      back: { x: 382, y: 178, w: 24, h: 24 },
      fwd: { x: 382, y: 224, w: 24, h: 24 },
      more: { x: 382, y: 270, w: 24, h: 24 },
      stackbg: { x: 372, y: 523, w: 44, h: 102 },
      plus: { x: 381, y: 537, w: 26, h: 26 },
      toggle: { ...hidden, x: 381, y: 587, w: 26, h: 26 },
      tabs: { x: 381, y: 587, w: 26, h: 26 },
      sidebar: { ...hidden, x: -290, y: 0, w: 270, h: 642 },
      pill: { x: 22, y: 565, w: 316, h: 42 },
      topbar: { ...hidden, x: 0, y: 0, w: 441, h: 0 },
      scrim: { ...hidden, x: 0, y: 0, w: 360, h: 642 },
    },
  },
};
const ORDER = Object.keys(LAYOUTS);
const SIDEBAR_TINT = "#fdedde";
const c = (n) => `calc(${n} * var(--c))`;

function place(el, { x, y, w, h, o = 1 }) {
  Object.assign(el.style, { left: c(x), top: c(y), width: c(w), height: c(h), opacity: o });
}
function applyLayout(device, name) {
  const L = LAYOUTS[name];
  const screen = device.querySelector(".m-screen");
  const bezel = 9;
  const corners = (tl, r) => `${c(tl)} ${c(r)} ${c(r)} ${c(tl)}`;
  Object.assign(device.style, {
    width: c(L.device.w),
    height: c(L.device.h),
    borderRadius: corners(L.device.tl, L.device.r),
  });
  Object.assign(screen.style, {
    left: c(bezel),
    top: c(bezel),
    width: c(L.device.w - bezel * 2),
    height: c(L.device.h - bezel * 2),
    borderRadius: corners(Math.max(L.device.tl - bezel, 2), L.device.r - bezel),
  });
  placeParts(device, name);
}
function placeParts(root, name) {
  const L = LAYOUTS[name];
  const screen = root.querySelector(".m-screen");
  const page = root.querySelector(".m-page");
  screen.style.setProperty("--m-bg", L.colors.bg);
  screen.style.setProperty("--m-fg", L.colors.fg);
  screen.style.setProperty("--m-chip", L.colors.chip);
  screen.style.setProperty("--m-chip-edge", L.colors.edge);
  screen.style.setProperty("--m-narrow", L.page.narrow);
  screen.style.setProperty("--m-side", SIDEBAR_TINT);
  place(page, L.page);
  page.style.borderRadius = c(L.page.r);
  for (const part of root.querySelectorAll("[data-m]")) place(part, L.parts[part.dataset.m]);
}

const section = document.getElementById("layouts");
const device = section.querySelector(".m-device");
const caption = document.getElementById("layout-caption");
const tabs = [...section.querySelectorAll(".t-tab")];
const tabPill = section.querySelector(".t-tabs-pill");
let current = "sidebar";
let cycle = 0;
let picked = false;
let inView = false;

function movePill(animate) {
  const tab = tabs.find((t) => t.dataset.layoutPick === current);
  if (!animate) tabPill.style.transition = "none";
  tabPill.style.transform = `translateX(${tab.offsetLeft}px)`;
  tabPill.style.width = `${tab.offsetWidth}px`;
  if (!animate) {
    void tabPill.offsetWidth;
    tabPill.style.transition = "";
  }
}
function pick(name, animate = true) {
  current = name;
  applyLayout(device, name);
  tabs.forEach((t) => t.setAttribute("aria-pressed", String(t.dataset.layoutPick === name)));
  movePill(animate);
  if (!animate) {
    caption.textContent = LAYOUTS[name].caption;
    return;
  }
  caption.classList.add("is-out");
  setTimeout(() => {
    caption.textContent = LAYOUTS[current].caption;
    caption.classList.remove("is-out");
  }, 150);
}
tabs.forEach((t) =>
  t.addEventListener("click", () => {
    picked = true;
    syncCycle();
    pick(t.dataset.layoutPick);
  }),
);
function syncCycle() {
  const run = inView && !paused && !picked;
  if (run && !cycle) {
    cycle = setInterval(() => pick(ORDER[(ORDER.indexOf(current) + 1) % ORDER.length]), 3200);
  } else if (!run && cycle) {
    clearInterval(cycle);
    cycle = 0;
  }
}

// The stylesheet reads these; the page's security policy doesn't allow them as inline styles.
for (const el of section.querySelectorAll(".m-map > *")) {
  for (const [key, value] of Object.entries(el.dataset)) el.style.setProperty(`--${key}`, value);
}

section.hidden = false;
pick("sidebar", false);
addEventListener("resize", () => movePill(false));
new IntersectionObserver(
  ([entry]) => {
    inView = entry.isIntersecting;
    syncCycle();
  },
  { threshold: 0.45 },
).observe(section.querySelector(".m-stage"));

// A phone-width window starts closed, which fills the screen better than a tiny open device.
if (matchMedia("(max-width: 640px)").matches) setPosture("closed");

// Once the page has arrived, the hero device draws itself in, once per visit, then its clip plays. The stencil
// traces an invisible copy of the layouts model, which is measured off the real app.
async function drawHero() {
  let seen = false;
  try {
    seen = sessionStorage.getItem("hero-drawn") === "1";
    sessionStorage.setItem("hero-drawn", "1");
  } catch {}
  if (seen) {
    stage.classList.add("is-ready");
    return;
  }
  const closed = stage.dataset.posture === "closed";
  const target = document.getElementById(closed ? "posture-closed" : "posture-open");
  const map = document.createElement("div");
  map.className = "m-device m-ghost";
  map.style.setProperty("--c", closed ? "calc(96.28cqw / 441)" : "calc(98.04cqw / 900)");
  map.append(device.querySelector(".m-screen").cloneNode(true));
  map.querySelector(".m-screen").removeAttribute("style");
  placeParts(map, closed ? "closed" : "sidebar");
  target.querySelector(".screen").append(map);
  target.style.borderRadius = `${target.offsetWidth * (closed ? 0.105 : 0.0473)}px`;
  heroDrawing = true;
  stage.classList.add("is-ready");
  sync();
  heroRun = generate(target, { mode: "skeleton", delay: 450, duration: 4200, maxParts: 60, keys: 5 });
  await heroRun.finished;
  heroRun = null;
  map.remove();
  target.style.borderRadius = "";
  heroDrawing = false;
  sync();
}
sync();
document.fonts.ready.then(drawHero);
