// What's New: every clip plays, muted and looping, while it's on screen, and pauses when it isn't.
// Clips never show the browser's own player controls: they sit over the content. If a browser
// won't autoplay (or Reduce Motion is on), the clip waits on its poster with a small play button,
// and clicking the clip plays or pauses it.
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const clips = [...document.querySelectorAll("video[data-loop]")];

for (const v of clips) {
  v.muted = true;
  v.loop = true;
  v.controls = false;
  v.disablePictureInPicture = true;
  v.disableRemotePlayback = true;
  const box = v.closest(".wn-media");
  // The play button shows only when a clip is stopped for a reason: you paused it, or the browser wouldn't start it.
  const sync = () => { if (!v.paused) delete v.dataset.blocked; box?.classList.toggle("is-paused", v.paused && !!(v.dataset.held || v.dataset.blocked || still)); };
  v.addEventListener("play", sync);
  v.addEventListener("pause", sync);
  box?.addEventListener("click", () => {
    if (v.paused) { delete v.dataset.held; v.play().catch(() => {}); }
    else { v.dataset.held = "1"; v.pause(); }
  });
  if (still) { v.pause(); v.autoplay = false; }
  sync();
}

if (!still) {
  const io = new IntersectionObserver((seen) => seen.forEach(({ target, isIntersecting }) => {
    if (isIntersecting) { if (!target.dataset.held) target.play().catch(() => { target.dataset.blocked = "1"; target.dispatchEvent(new Event("pause")); }); }
    else target.pause();
  }), { threshold: 0.25 });
  clips.forEach((v) => io.observe(v));
}

// Browsers that only play after a click (Browsa included) start the clips on the first click or key
// anywhere on the page, rather than leaving every clip waiting on its own play button.
const wake = () => {
  if (still) return;
  for (const v of clips) {
    const r = v.getBoundingClientRect();
    if (!v.dataset.held && r.bottom > 0 && r.top < innerHeight) v.play().catch(() => {});
  }
};
addEventListener("pointerdown", wake, { once: true, capture: true });
addEventListener("keydown", wake, { once: true, capture: true });
