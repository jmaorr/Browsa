// report.html for a sweep (sweep.mjs) and for a call (aftercall.mjs): scores, the offset curve and the clips,
// playable in place. Plain HTML, no scripts or network; files sit next to the clips they play.
import fs from "node:fs";
import path from "node:path";

const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const num = (v, d = 1) => (v == null || !isFinite(v) ? "–" : (+v).toFixed(d));

const CSS = `
:root { --bg:#fbfaf8; --fg:#1d1d1f; --muted:#6b6b70; --line:#e3e1dc; --card:#fff; --good:#2f7d4f; --warn:#a86b00; --bad:#b3261e; --accent:#3d5afe; }
@media (prefers-color-scheme: dark) { :root { --bg:#141416; --fg:#ececef; --muted:#9a9aa2; --line:#2b2b30; --card:#1c1c20; --good:#5cc78a; --warn:#e0a83a; --bad:#ff7a70; --accent:#8c9eff; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 32px 16px 64px; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 32px 0 10px; }
.muted { color: var(--muted); } .mono { font: 12px/1.4 ui-monospace, Menlo, monospace; }
.headline { margin: 18px 0; padding: 14px 16px; background: var(--card); border: 1px solid var(--line); border-radius: 10px; }
.headline b { font-size: 17px; }
.clips { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; }
.clip { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 12px; }
.clip div { margin-bottom: 6px; font-weight: 600; } .clip p { margin: 6px 0 0; font-size: 13px; color: var(--muted); }
audio { width: 100%; }
.table { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { color: var(--muted); font-weight: 600; } tr:last-child td { border-bottom: 0; }
tr.best td { background: color-mix(in srgb, var(--accent) 10%, transparent); }
.good { color: var(--good); } .warn { color: var(--warn); } .bad { color: var(--bad); }
.bar { display:inline-block; height: 8px; border-radius: 4px; background: var(--accent); vertical-align: middle; margin-right: 6px; }
svg text { fill: var(--muted); font-size: 11px; } svg .axis { stroke: var(--line); } svg .curve { stroke: var(--accent); fill: none; stroke-width: 2; }
svg .dot { fill: var(--accent); } svg .ok { fill: color-mix(in srgb, var(--good) 12%, transparent); } svg .ann { fill: color-mix(in srgb, var(--bad) 10%, transparent); }
ul { padding-left: 20px; } li { margin: 3px 0; }
`;

const grade = (f) => (f == null ? "" : f >= 14 ? "good" : f > 8 ? "warn" : "bad");
const fCell = (s) => `<span class="${grade(s?.margin)}">${s?.marginIsLowerBound ? "≥" : ""}${num(s?.margin)}</span>`;
const clip = (file, title, note, dir) => (fs.existsSync(path.join(dir, file)) ? `<div class="clip"><div>${esc(title)}</div><audio controls preload="none" src="${esc(file)}"></audio><p>${esc(note)}</p></div>` : "");

function offsetChart(variants) {
  const pts = variants.filter((v) => v.label.startsWith("reference ") || v.label === "recorded settings").filter((v) => v.score.margin != null)
    .map((v) => ({ x: v.shiftMs, y: Math.max(-10, Math.min(40, v.score.margin)) })).sort((a, b) => a.x - b.x);
  if (pts.length < 3) return "";
  const W = 640, H = 220, L = 40, R = 12, T = 12, B = 30;
  const xs = pts.map((p) => p.x), x0 = Math.min(...xs), x1 = Math.max(...xs);
  const X = (x) => L + ((x - x0) / (x1 - x0 || 1)) * (W - L - R), Y = (y) => T + ((40 - y) / 50) * (H - T - B);
  const ticksX = xs.filter((x, i) => i % 2 === 0 || x === 0).map((x) => `<text x="${X(x)}" y="${H - 10}" text-anchor="middle">${x > 0 ? "+" : ""}${x}</text>`).join("");
  const ticksY = [-10, 0, 8, 14, 20, 30, 40].map((y) => `<text x="${L - 6}" y="${Y(y) + 4}" text-anchor="end">${y}</text><line class="axis" x1="${L}" x2="${W - R}" y1="${Y(y)}" y2="${Y(y)}"/>`).join("");
  return `<h2>Echo against reference offset</h2><p class="muted">G.131 margin f (shown -10..40) for each reference offset, other settings as recorded. Green band: acceptable (14+); red: annoying (8 or less).</p>
<div class="table"><svg viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="Echo margin by reference offset">
<rect class="ok" x="${L}" y="${Y(40)}" width="${W - L - R}" height="${Y(14) - Y(40)}"/><rect class="ann" x="${L}" y="${Y(8)}" width="${W - L - R}" height="${Y(-10) - Y(8)}"/>
${ticksY}${ticksX}<polyline class="curve" points="${pts.map((p) => `${X(p.x)},${Y(p.y)}`).join(" ")}"/>${pts.map((p) => `<circle class="dot" cx="${X(p.x)}" cy="${Y(p.y)}" r="3"/>`).join("")}
<text x="${(L + W - R) / 2}" y="${H}" text-anchor="middle">reference offset, ms (later +)</text></svg></div>`;
}

function variantTable(r) {
  const rows = r.variants.slice().sort((a, b) => (b.score.rank ?? -1e9) - (a.score.rank ?? -1e9)).map((v) => {
    const s = v.score, w = Math.max(2, Math.round(((s.rank ?? 0) + 5) * 4));
    return `<tr class="${v === r.best || v.label === r.best.label ? "best" : ""}"><td>${esc(v.label)}</td><td><span class="bar" style="width:${w}px"></span>${num(s.rank, 2)}</td><td>${fCell(s)}</td><td>${num(s.audiblePct)}%</td><td>${num(s.echoLossDb)}</td><td>${num(s.sendLevelDb)}</td></tr>`;
  }).join("");
  return `<div class="table"><table><thead><tr><th>variant</th><th>rank</th><th>G.131 f</th><th>echo audible</th><th>echo loss dB</th><th>send dBFS</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function sweepBody(r, dir, prefix = "") {
  const live = r.live;
  return `<div class="headline"><b>Best: ${esc(r.bestEnv)}</b> <span class="muted">(${esc(r.best.label)})</span><br>
Now: f ${fCell(live || r.variants[0].score)}${live ? "" : " (replay)"}, audible ${num((live || r.variants[0].score).audiblePct)}% → at best: f ${fCell(r.best.score)}, audible ${num(r.best.score.audiblePct)}%</div>
<div class="clips">
${clip(prefix + "live-guest-hears.m4a", "Guest hears, as sent live", "Far-only stretches: their voice coming back to them.", dir)}
${clip(prefix + "best-guest-hears.m4a", "Guest hears, best setting (replay)", "Same stretches, replayed with the best setting.", dir)}
${clip(prefix + "live-guest-hears-plus30dB.m4a", "As sent live, +30 dB", "Faint leftovers made audible.", dir)}
${clip(prefix + "best-guest-hears-plus30dB.m4a", "Best setting, +30 dB", "", dir)}
</div>
${offsetChart(r.variants)}
<h2>All variants</h2>${variantTable(r)}
<ul class="muted">
<li>Rank: G.131 margin capped at 20, less 0.25 per % of their speech with audible echo, less a send-level penalty (more than 6 dB from -26 dBFS). Ties within 0.5 go to the fewest changes.</li>
<li>Replay vs live: ${r.replayVsLiveDb != null ? `${num(r.replayVsLiveDb)} dB (about -30 or lower means the replay reproduces the call; higher means treat the sweep as indicative)` : "no live sent.wav"}.</li>
<li>Echo path ${num(r.echoLagMs, 0)} ms; far-only audio judged: ${num(r.stretches.farOnlySec)} s of the first ${num(r.minutesUsed)} min.</li>
</ul>`;
}

const page = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title><style>${CSS}</style></head><body><main>${body}</main></body></html>\n`;

export function writeSweepHtml(r, dir) {
  const body = `<h1>Call audio sweep</h1><p class="muted mono">${esc(r.dump)}<br>recorded settings ${esc(JSON.stringify(r.recorded))}</p>${sweepBody(r, dir)}`;
  fs.writeFileSync(path.join(dir, "report.html"), page("Call audio sweep", body));
}

export function writeCallHtml(score, dir, sweep) {
  const s = score;
  const body = `<h1>After the call</h1><p class="muted mono">${esc(s.dump)}<br>${num(s.minutes)} min · settings ${esc(JSON.stringify(s.settings || "unknown"))}${s.complete === false ? " · dump not closed cleanly (valid up to the last half second)" : ""}</p>
<div class="headline"><b>Guest's ear: f ${fCell(s)}</b> <span class="muted">(14+ fine, 8 or less annoying)</span><br>
Echo audible in ${num(s.audiblePct)}% of their speech · echo loss ${num(s.echoLossDb)} dB · your voice sent at ${num(s.sendLevelDb)} dBFS (nominal about -26)</div>
<div class="clips">
${clip("guest-hears.m4a", "What they heard of themselves", "Sent audio over the stretches where only they talked.", dir)}
${clip("guest-hears-plus30dB.m4a", "Same, +30 dB", "Faint leftovers made audible.", dir)}
${clip("you-sent.m4a", "Your voice as sent", "Stretches where only you talked.", dir)}
</div>
<h2>What a real call can and can't show</h2><ul>
<li><b>Far only, ${num(s.farOnlySec)} s:</b> the other side talking, you quiet. All echo figures come from here.</li>
<li><b>You only, ${num(s.nearOnlySec)} s:</b> send level ${num(s.sendLevelDb)} dBFS, voice kept ${num(s.voiceKeptDb)} dB against the raw mic.</li>
<li><b>Both or unclear, ${num(s.mixedSec)} s:</b> not scored. Talk-over and gain pumping need a known talker (the bench).</li>
<li>Room as sent ${num(s.floorDb)} dBFS · echo path ${num(s.echoLagMs, 0)} ms.</li>
${s.worst?.length ? `<li>Worst moments (call time, echo loss): ${s.worst.map((w) => `${w.callTime != null ? `${Math.floor(w.callTime / 60)}:${String(Math.floor(w.callTime % 60)).padStart(2, "0")}` : "?"} ${num(w.lossDb)} dB`).join(", ")}</li>` : "<li>No audible echo moments.</li>"}
</ul>
${sweep ? `<h2>Offline sweep</h2>${sweepBody(sweep, dir, "sweep/")}` : ""}`;
  fs.writeFileSync(path.join(dir, "report.html"), page("After the call", body));
}
