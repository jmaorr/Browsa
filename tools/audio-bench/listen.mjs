#!/usr/bin/env node
// Listening clips: what the other person on the call would get back, per subject, as small AAC files plus
// a one-page listen.html laying them out side by side with the guest's-ear scores. Nothing is played.
//   node tools/audio-bench/listen.mjs <run folder> <out folder> [subject ids, comma separated]
// Per subject:  <name>-1-far-end-only.m4a   what comes back while only they talk, as sent
//               <name>-2-far-end-only-plus30dB.m4a   the same, 30 dB louder, so faint leak is obvious
//               <name>-3-talk-over.m4a      while you both talk, as sent
// These are recordings of a real room: keep them out of git.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { RATE, readWav, writeWavFloat } from "./analyze.mjs";

const [runDir, outDir, only] = process.argv.slice(2);
if (!runDir || !outDir) { console.error("usage: listen.mjs <run folder> <out folder> [subject ids]"); process.exit(1); }
const result = JSON.parse(fs.readFileSync(path.join(runDir, "results.json"), "utf8"));
const want = only ? only.split(",") : null;
fs.mkdirSync(outDir, { recursive: true });
const tmp = fs.mkdtempSync(path.join(outDir, ".tmp-"));

const slug = (s) => s.toLowerCase().replace(/\(.*?\)/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
function clip(x, a, b, gain) {
  const out = new Float32Array(Math.max(0, Math.floor(b) - Math.floor(a)));
  for (let i = 0; i < out.length; i++) out[i] = Math.max(-1, Math.min(1, (x[Math.floor(a) + i] || 0) * gain));
  // 30 ms fades so the clip edges don't click.
  const f = Math.min(1440, out.length >> 1);
  for (let i = 0; i < f; i++) { out[i] *= i / f; out[out.length - 1 - i] *= i / f; }
  return out;
}
function m4a(data, file) {
  const wav = path.join(tmp, path.basename(file, ".m4a") + ".wav");
  writeWavFloat(wav, [data], RATE);
  execFileSync("afconvert", ["-f", "m4af", "-d", "aac", "-b", "64000", "-c", "1", wav, file]);
  fs.unlinkSync(wav);
}

const cards = [];
for (const s of result.subjects) {
  if (s.status !== "ok" || (want && !want.includes(s.id))) continue;
  const a = s.analysis, w = a.windows, sent = readWav(path.join(s.dir, "sent.wav")).channels[0];
  const name = `${slug(s.name.replace(/@ volume (\d+)/, "vol $1"))}`;
  const files = [
    [`${name}-1-far-end-only.m4a`, clip(sent, w.far[0] * RATE, w.far[1] * RATE, 1), "Far end only, as sent"],
    [`${name}-2-far-end-only-plus30dB.m4a`, clip(sent, w.far[0] * RATE, w.far[1] * RATE, 31.62), "Same, +30 dB"],
    [`${name}-3-talk-over.m4a`, clip(sent, w.both[0] * RATE, w.both[1] * RATE, 1), "Both talking, as sent"],
  ];
  for (const [f, data] of files) m4a(data, path.join(outDir, f));
  cards.push({ s, files: files.map(([f, , label]) => ({ f, label, bytes: fs.statSync(path.join(outDir, f)).size })) });
  console.log(`${s.name}: ${files.map(([f]) => f).join(", ")}`);
}
fs.rmSync(tmp, { recursive: true, force: true });

const esc = (t) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const n = (v, d = 1) => (v == null || !isFinite(v) ? "–" : (+v).toFixed(d));
const grade = (f) => (f == null ? "" : f >= 14 ? "good" : f > 8 ? "warn" : "bad");
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Echo listening test</title>
<style>
:root { --bg:#fbfbfa; --fg:#1c1c1a; --muted:#6b6b66; --line:#dddcd6; --card:#fff; --good:#13521f; --goodbg:#d8f0dc; --warn:#6b4a00; --warnbg:#fbeccb; --bad:#7a1b12; --badbg:#f8d6d3; }
@media (prefers-color-scheme: dark) { :root { --bg:#161615; --fg:#ecebe6; --muted:#9d9c95; --line:#36352f; --card:#1f1f1d; --good:#a8e2b4; --goodbg:#183a20; --warn:#f0d48f; --warnbg:#3d3112; --bad:#f3aaa1; --badbg:#45201c; } }
body { background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; margin:0; padding:24px 16px 48px; }
main { max-width:1100px; margin:0 auto; } h1 { font-size:22px; margin:0 0 6px; } p { margin:0 0 12px; } .muted { color:var(--muted); }
.grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(250px, 1fr)); gap:14px; margin-top:18px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; }
.card h2 { font-size:15px; margin:0 0 8px; } .score { display:inline-block; padding:2px 8px; border-radius:6px; font-variant-numeric:tabular-nums; font-size:13px; margin-bottom:6px; }
.good { background:var(--goodbg); color:var(--good); } .warn { background:var(--warnbg); color:var(--warn); } .bad { background:var(--badbg); color:var(--bad); }
dl { display:grid; grid-template-columns:auto 1fr; gap:2px 10px; font-size:13px; margin:6px 0 10px; font-variant-numeric:tabular-nums; } dt { color:var(--muted); } dd { margin:0; }
.clip { margin:8px 0 0; font-size:13px; } audio { width:100%; height:34px; margin-top:2px; }
</style></head><body><main>
<h1>What the other person hears back</h1>
<p class="muted">Each card is one audio path at system volume ${esc(cards[0]?.s.volume)}. The far end (the other person) is the standup recording; "you" are a synthetic
voice on a second speaker. The clips are what Browsa would send them: during their own speech any of their voice you hear is echo, and in the
talk-over clip their voice under yours is leak. Listen on headphones at low volume, the +30 dB clips first. Your ear decides; the score only
picks candidates.</p>
<p class="muted">Score: ITU-T G.131 talker-echo rule for an assumed ${esc(cards[0]?.s.analysis.guest.oneWayMs)} ms one-way network delay. f ≥ 14 acceptable, 8–14 probably annoying, ≤ 8 annoying.
"Audible" counts 200 ms stretches of their speech where the echo is above the sent noise and under the acceptable loss.</p>
<div class="grid">${cards.map(({ s, files }) => {
  const g = s.analysis.guest, f = g.segments.far || {}, b = g.segments.both || {};
  return `<section class="card"><h2>${esc(s.name)}</h2>
<span class="score ${grade(f.g131Margin)}">G.131 f ${f.echoLossIsLowerBound ? "≥ " : ""}${n(f.g131Margin)}</span>
<dl><dt>Echo loss</dt><dd>${f.echoLossIsLowerBound ? "≥ " : ""}${n(f.echoLossDb)} dB (needs ${n(g.requiredLossDb.acceptable)})</dd>
<dt>Audible</dt><dd>${n(f.audiblePct)}% of their speech (${n(f.audibleSec)} s)</dd>
<dt>Worst moment</dt><dd>${f.worst ? `${n(f.worst.t)} s, ${n(f.worst.lossDb)} dB under their voice` : "none above the noise"}</dd>
<dt>Talk-over</dt><dd>loss ${b.echoLossIsLowerBound ? "≥ " : ""}${n(b.echoLossDb)} dB, f ${b.echoLossIsLowerBound ? "≥ " : ""}${n(b.g131Margin)}, audible ${n(b.audiblePct)}%</dd>
<dt>Sent noise</dt><dd>${n(s.analysis.floorDb)} dBFS</dd></dl>
${files.map((c) => `<div class="clip">${esc(c.label)}<audio controls preload="none" src="${esc(c.f)}"></audio></div>`).join("")}
</section>`;
}).join("")}</div>
</main></body></html>`;
fs.writeFileSync(path.join(outDir, "listen.html"), html);
console.log(`Wrote ${path.join(outDir, "listen.html")}`);
