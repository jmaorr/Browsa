// What's New: every clip plays, muted and looping, while it's on screen, and pauses when it isn't.
// With Reduce Motion on, clips wait on their poster with a play button instead.
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const clips = [...document.querySelectorAll("video[data-loop]")];
for (const v of clips) { v.muted = true; v.loop = true; }
if (still) {
  clips.forEach((v) => { v.pause(); v.autoplay = false; v.controls = true; });
} else {
  const io = new IntersectionObserver((seen) => seen.forEach(({ target, isIntersecting }) => {
    if (isIntersecting) target.play().catch(() => { target.controls = true; });
    else target.pause();
  }), { threshold: 0.25 });
  clips.forEach((v) => io.observe(v));
}
