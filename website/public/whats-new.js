// What's New: each short demo plays, muted and looping, only while it's on screen. With reduced
// motion it stays on its poster and gets a play button instead.
const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
const clips = [...document.querySelectorAll("video[data-loop]")];
if (still) {
  clips.forEach((v) => { v.loop = false; v.controls = true; });
} else {
  const io = new IntersectionObserver((seen) => seen.forEach(({ target, isIntersecting }) => {
    if (isIntersecting) target.play().catch(() => { target.controls = true; });
    else target.pause();
  }), { threshold: 0.4 });
  clips.forEach((v) => io.observe(v));
}
