// Shared bits for the 1.3 What's New clips: a pointer that walks through stops and clicks,
// a context menu, and the window's page box for positions. Uses ../../kit and ../../library/shared.
const $ = (id) => document.getElementById(id);
const ART = (id) => `../../../../../Mac/Resources/Library/Art/library-${id}.jpg`;
const box = (el, root) => { const r = el.getBoundingClientRect(), p = (root || document.body).getBoundingClientRect(); return { x: r.left - p.left, y: r.top - p.top, w: r.width, h: r.height, cx: r.left - p.left + r.width / 2, cy: r.top - p.top + r.height / 2 }; };
// stops: [[time, [x, y]], ...]; moves ease between them. clicks: [time, ...] draw a ring where the pointer is.
function pointer(t, stops, clicks, out = TOTAL - 1.2) {
  let [x, y] = stops[0][1];
  for (let i = 1; i < stops.length; i++) { const a = stops[i - 1][0] + 0.1, d = stops[i][0] - stops[i - 1][0] - 0.2; const m = eio(ph(t, a, Math.max(d, 0.01))); x = mix(x, stops[i][1][0], m); y = mix(y, stops[i][1][1], m); }
  $("ptr").style.left = x + "px"; $("ptr").style.top = y + "px";
  $("ptr").style.opacity = Math.min(ph(t, stops[0][0], 0.3), 1 - ph(t, out, 0.4));
  let ring = 0;
  for (const c of clicks) if (t > c && t < c + 0.45) { const k = ph(t, c, 0.45); ring = 1 - k; $("ring").style.left = x + "px"; $("ring").style.top = y + "px"; $("ring").style.transform = `scale(${0.5 + k})`; }
  $("ring").style.opacity = ring;
  return [x, y];
}
const fadeIn = (t, a, d = 0.3) => eo(ph(t, a, d));
const shown = (t, a, b, d = 0.25) => Math.min(ph(t, a, d), 1 - ph(t, b, d));
