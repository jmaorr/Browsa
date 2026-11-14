// Audio Bench report: one self-contained HTML page (inline SVG, light and dark).
import { METRICS, grade } from "./analyze.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const num = (v, d = 1) => (v == null || !isFinite(v) ? "–" : v <= -149 ? "silent" : (+v).toFixed(d));

function strip(r) {
  const s = r.analysis?.strip;
  if (!s) return "";
  const W = 960, H = 150, top = -10, bottom = -90, n = s.sent.length, dur = n * s.frameSec || 1;
  const x = (t) => ((t / dur) * W).toFixed(1), y = (d) => ((Math.min(top, Math.max(bottom, d)) - top) / (bottom - top) * H).toFixed(1);
  const line = (arr, cls) => arr ? `<polyline class="${cls}" points="${arr.map((v, i) => `${x(i * s.frameSec)},${y(v)}`).join(" ")}"/>` : "";
  const names = ["quiet", "far end", "you", "both", "quiet"], cls = ["q", "f", "n", "d", "q"];
  let bands = "";
  for (let i = 0; i < 5; i++) {
    const a = s.boundaries[i], b = s.boundaries[i + 1];
    if (b <= a) continue;
    bands += `<rect class="seg ${cls[i]}" x="${x(a)}" y="0" width="${(x(b) - x(a)).toFixed(1)}" height="${H}"/><text class="seglabel" x="${Math.max(2, +x(a) + 4).toFixed(1)}" y="12">${names[i]}</text>`;
  }
  let grid = "";
  for (const d of [-20, -40, -60, -80]) grid += `<line class="grid" x1="0" x2="${W}" y1="${y(d)}" y2="${y(d)}"/><text class="gridlabel" x="${W - 4}" y="${+y(d) - 3}">${d}</text>`;
  const act = (arr, cls, yy) => arr.map((v, i) => (v > -60 ? `<rect class="${cls}" x="${x(i * s.frameSec)}" y="${yy}" width="${(W / n + 0.5).toFixed(1)}" height="4"/>` : "")).join("");
  return `<svg viewBox="0 0 ${W} ${H + 14}" role="img" aria-label="Sent level over time for ${esc(r.name)}">
${bands}${grid}${line(s.raw, "raw")}${line(s.sent, "sent")}
${act(s.far, "actf", H + 2)}${act(s.near, "actn", H + 8)}</svg>`;
}

function inputsTable(r) {
  const ins = r.analysis?.inputs;
  if (!ins?.length) return "";
  return `<table class="small"><thead><tr><th>Device input</th><th>Quiet</th><th>Far end only</th><th>You only</th><th>Follows far end</th><th>Follows you</th><th>Looks like</th></tr></thead><tbody>${ins
    .map((i) => `<tr><td>${i.input}</td><td>${num(i.floorDb)}</td><td>${num(i.farDb)}</td><td>${num(i.nearDb)}</td><td>${num(i.farCorrelation, 2)}</td><td>${num(i.nearCorrelation, 2)}</td><td>${esc(i.role)}</td></tr>`)
    .join("")}</tbody></table>`;
}

function details(r) {
  const a = r.analysis || {}, m = r.meta || {};
  const facts = [];
  if (m.input) facts.push(`Mic: ${esc(m.input)}${m.inputRate ? ` (${m.inputRate} Hz)` : ""}`);
  if (m.output) facts.push(`Speakers: ${esc(m.output)}`);
  if (m.talkerOutput) facts.push(`Talker: ${esc(m.talkerOutput)}`);
  if (r.volume != null) facts.push(`Volume ${r.volume}`);
  if (a.farLagMs != null) facts.push(`far end found ${Math.round(a.farLagMs)} ms from the schedule in the recording, talker ${Math.round(a.nearLagMs)} ms`);
  if (a.windows5s) facts.push(`5 s echo windows: ${a.windows5s.join(" ")} dB`);
  if (a.roomEchoAboveQuietDb != null && m.mode === "raw") facts.push(`room echo at the mic ${num(a.roomEchoAboveQuietDb)} dB above quiet`);
  else if (a.roomEchoAboveQuietDb != null) facts.push(`room echo at the mic ${num(a.roomEchoAboveQuietDb)} dB above quiet; canceller removed ${num(a.echoRemovedDb)} dB of the correlated echo`);
  if (a.voiceKeptDb != null && m.mode !== "raw") facts.push(`your voice ${num(a.voiceKeptDb)} dB against the raw mic (${num(a.rawSendLevelDb)} dBFS raw)`);
  if (m.delayMs != null && m.mode === "webrtc") facts.push(`canceller delay ${num(m.delayMs, 0)} ms, drift ${num(m.driftPpm)} ppm, resyncs ${m.resyncs}, misses ${m.referenceMisses}, clock resets ${m.clockResets}`);
  if (r.notes) facts.push(esc(r.notes));
  return `<ul class="facts">${facts.map((f) => `<li>${f}</li>`).join("")}</ul>`;
}

export function renderReport(run) {
  const subjects = run.subjects;
  const head = METRICS.map((m) => `<th title="${esc(m.help)}">${esc(m.label)}<br><span class="unit">${m.unit}</span></th>`).join("");
  const rows = subjects
    .map((r) => {
      if (r.status !== "ok") return `<tr><th scope="row">${esc(r.name)}</th><td class="skip" colspan="${METRICS.length}">${esc(r.status)}</td></tr>`;
      const g = grade(r.analysis);
      return `<tr><th scope="row"><a href="#${esc(r.id)}">${esc(r.name)}</a></th>${METRICS.map((m) => `<td class="${g[m.key]}">${num(r.analysis[m.key], m.key === "clippedPct" || m.key === "echoRhythm" ? 2 : 1)}</td>`).join("")}</tr>`;
    })
    .join("");
  const sections = subjects
    .filter((r) => r.status === "ok")
    .map((r) => `<section id="${esc(r.id)}"><h2>${esc(r.name)}</h2>${strip(r)}${details(r)}${inputsTable(r)}<p class="files">Files: ${esc(r.dir)}</p></section>`)
    .join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Audio Bench</title>
<style>
:root { --bg:#fbfbfa; --fg:#1c1c1a; --muted:#6b6b66; --line:#dddcd6; --good:#d8f0dc; --goodfg:#13521f; --warn:#fbeccb; --warnfg:#6b4a00; --bad:#f8d6d3; --badfg:#7a1b12;
  --sent:#2b62d9; --raw:#a3a39b; --f:#e9e3f7; --n:#e1f1e7; --d:#f7e6dc; --q:transparent; --actf:#8a6dd1; --actn:#3a9a5e; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#161615; --fg:#ecebe6; --muted:#9d9c95; --line:#36352f; --good:#183a20; --goodfg:#a8e2b4; --warn:#3d3112; --warnfg:#f0d48f; --bad:#45201c; --badfg:#f3aaa1;
  --sent:#7aa5ff; --raw:#5e5e58; --f:#2a2340; --n:#1d3326; --d:#3b2a20; --actf:#a790e6; --actn:#66c48a; } }
:root[data-theme="dark"] { --bg:#161615; --fg:#ecebe6; --muted:#9d9c95; --line:#36352f; --good:#183a20; --goodfg:#a8e2b4; --warn:#3d3112; --warnfg:#f0d48f; --bad:#45201c; --badfg:#f3aaa1;
  --sent:#7aa5ff; --raw:#5e5e58; --f:#2a2340; --n:#1d3326; --d:#3b2a20; --actf:#a790e6; --actn:#66c48a; }
body { background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; margin:0; padding:24px 16px 48px; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:16px; margin:28px 0 8px; }
.muted, .unit, .files { color:var(--muted); } .unit { font-weight:400; font-size:11px; }
.scroll { overflow-x:auto; }
table { border-collapse:collapse; width:100%; font-variant-numeric:tabular-nums; }
th, td { border-bottom:1px solid var(--line); padding:6px 8px; text-align:right; white-space:nowrap; }
th { font-weight:600; font-size:12px; vertical-align:bottom; } th[scope=row] { text-align:left; }
td.good { background:var(--good); color:var(--goodfg); } td.warn { background:var(--warn); color:var(--warnfg); } td.bad { background:var(--bad); color:var(--badfg); }
td.skip { text-align:left; color:var(--muted); }
table.small { width:auto; margin-top:8px; } table.small td, table.small th { font-size:12px; }
a { color:var(--sent); }
svg { width:100%; height:auto; display:block; margin-top:4px; }
.seg.f { fill:var(--f); } .seg.n { fill:var(--n); } .seg.d { fill:var(--d); } .seg.q { fill:var(--q); }
.seglabel, .gridlabel { fill:var(--muted); font-size:11px; } .gridlabel { text-anchor:end; }
.grid { stroke:var(--line); stroke-width:1; }
polyline { fill:none; stroke-width:1.4; } .sent { stroke:var(--sent); } .raw { stroke:var(--raw); stroke-width:1; }
.actf { fill:var(--actf); } .actn { fill:var(--actn); }
.facts { margin:6px 0 0; padding-left:18px; color:var(--muted); font-size:12.5px; }
.legend span { display:inline-block; margin-right:14px; } .sw { display:inline-block; width:10px; height:10px; border-radius:2px; margin-right:5px; vertical-align:-1px; }
</style></head><body><main>
<h1>Audio Bench</h1>
<p class="muted">${esc(run.startedAt)} · ${esc(run.description)}</p>
<div class="scroll"><table><thead><tr><th scope="col" style="text-align:left">Subject</th>${head}</tr></thead><tbody>${rows}</tbody></table></div>
<p class="muted legend"><span><i class="sw" style="background:var(--sent)"></i>sent</span><span><i class="sw" style="background:var(--raw)"></i>raw mic</span><span><i class="sw" style="background:var(--actf)"></i>far end playing</span><span><i class="sw" style="background:var(--actn)"></i>talker playing</span>Hover a column for what it measures.</p>
${sections}
</main></body></html>`;
}
