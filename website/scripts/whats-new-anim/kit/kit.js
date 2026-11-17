// Timing helpers for the explainers. Each page defines render(t) and TOTAL (seconds).
const clamp = (x) => Math.min(1, Math.max(0, x));
const ph = (t, a, d) => clamp((t - a) / d);
const eo = (x) => 1 - Math.pow(1 - x, 3);
const eio = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
const mix = (a, b, f) => a + (b - a) * f;
const fav = (name) => `../../../public/media/fav/${name}.png`;
const row = (icon, title, cls = "") => `<div class="row ${cls}"><div class="in"><img src="${icon}"><span>${title}</span></div></div>`;
// Fades the whole stage in and out at the loop point.
const loopFade = (t, total) => Math.min(ph(t, 0, 0.3), 1 - ph(t, total - 0.45, 0.45));
