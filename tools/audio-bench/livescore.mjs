#!/usr/bin/env node
// Scores a live talk-over run: a person talks over the far end into the mic on a fixed script (no stand-in talker),
// run with `run.sh --subjects spike,chrome --no-talker --long 3`. Every subject is scored the same way, from what it
// sent and the known far-end recording only:
//   node tools/audio-bench/livescore.mjs <run folder> [--talk 20-40,60-80,100-120,140-160] [--slack 2]
// --detect: find the talking from the sent level instead (scripts drift).
// --talk: the reading windows, seconds from when the far end starts (the rest is far end only); --slack trims that
// much off each side of every window, so script timing slips don't mix the two.
// Per subject and window kind: the far end's echo in what was sent (coherent with the far-end recording, dBFS, and
// below the far end's own level as it was played, dB), how much of the far-end time carried audible echo (200 ms
// blocks whose echo is within 45 dB of the far end, the G.131 need for a 300 ms one-way call), and in the reading
// windows the sent level (your voice) and how far the echo sat below it. For a spike subject with a unit dump, your
// actual speech is also found in the raw mic (louder than the echo alone would make it).
import fs from "node:fs";
import path from "node:path";
import { RATE, readWav, power, db, boundaries, scheduled } from "./analyze.mjs";
import { scoreSent } from "./dumpscore.mjs";

const argv = process.argv.slice(2);
const opt = { talk: "20-40,60-80,100-120,140-160", slack: "2", detect: "" };
let run = null;
for (let i = 0; i < argv.length; i++) { if (argv[i] === "--detect") opt.detect = "1"; else if (argv[i].startsWith("--")) opt[argv[i].slice(2)] = argv[++i]; else run = argv[i]; }
if (!run) { console.error("usage: livescore.mjs <run folder> [--talk 20-40,...] [--slack 2]"); process.exit(1); }
const results = JSON.parse(fs.readFileSync(path.join(run, "results.json"), "utf8"));
const b = boundaries(results.schedule);
const far = scheduled(readWav(results.farStimulus).channels[0], b, "far");
const slack = parseFloat(opt.slack);
const farStart = b[1] / RATE, farEnd = b[2] / RATE;
const talk = opt.talk.split(",").map((w) => w.split("-").map(Number));
// Far-end-only windows: the gaps between reading windows (and before the first, after the last).
const edges = [0, ...talk.flat(), farEnd - farStart];
const quiet = [];
for (let i = 0; i < edges.length; i += 2) if (edges[i + 1] - edges[i] > 2 * slack + 2) quiet.push([edges[i], edges[i + 1]]);
const trim = (ws) => ws.map(([a, z]) => [a + slack, z - slack]).filter(([a, z]) => z - a >= 2);

// The same guest's-ear scoring as call dumps (dumpscore.mjs): the windows are given as the "far end" stretches.
function score(sent, lagSamples, windows) {
  const spans = windows.map(([a, z]) => [Math.floor((farStart + a) * RATE) + lagSamples, Math.floor((farStart + z) * RATE) + lagSamples])
    .filter(([a, z]) => a >= 0 && z <= sent.length);
  const st = { far: spans, near: [], both: [], quiet: [] };
  const r = scoreSent(sent, far, null, st, lagSamples);
  let sentP = 0, n = 0;
  for (const [a, z] of spans) { sentP += power(sent, a, z) * (z - a); n += z - a; }
  return { seconds: +(n / RATE).toFixed(0), echoLossDb: r.echoLossDb, lowerBound: r.marginIsLowerBound, g131: r.margin, audiblePct: r.audiblePct,
    sentDbfs: +db(sentP / Math.max(1, n)).toFixed(1) };
}

const rows = [];
for (const s of results.subjects) {
  if (s.status !== "ok") { rows.push({ name: s.name, status: s.status }); continue; }
  const sent = readWav(path.join(s.dir, "sent.wav")).channels[0];
  const lag = Math.round(((s.analysis?.farLagMs ?? 0) * RATE) / 1000);
  let tw = talk, qw = quiet;
  if (opt.detect) {
    // Find the talking from what was sent: 1 s blocks over -40 dBFS are you (the far end's leftovers sit far
    // below), under -45 dBFS far end only; merged, then trimmed by the slack like the scripted windows.
    const lv = [];
    for (let t = 0; t + 1 <= farEnd - farStart; t++) { const a0 = Math.floor((farStart + t) * RATE) + lag; lv.push(db(power(sent, a0, a0 + RATE))); }
    const runs = (pred) => { const out = []; let st = -1; lv.forEach((l, i) => { if (pred(l)) { if (st < 0) st = i; } else if (st >= 0) { out.push([st, i]); st = -1; } }); if (st >= 0) out.push([st, lv.length]); return out; };
    tw = runs((l) => l > -40); qw = runs((l) => l < -45);
  }
  const row = { name: s.name, talkWindows: tw, farOnly: score(sent, lag, trim(qw)), talkOver: score(sent, lag, trim(tw)) };
  if (s.drift) row.drift = { gapPpm: s.drift.clocks?.gapPpm, echoPathSlopeMsPerMin: s.drift.echoPath?.slopeMsPerMin, echoPathSpreadMs: s.drift.echoPath?.spanMs };
  rows.push(row);
}
fs.writeFileSync(path.join(run, "livescore.json"), JSON.stringify({ talkWindows: talk, farOnlyWindows: quiet, slack, rows }, null, 2));
for (const r of rows) {
  if (r.status) { console.log(`${r.name}: ${r.status}`); continue; }
  const f = (x) => `echo loss ${x.lowerBound ? "≥" : ""}${x.echoLossDb} dB, G.131 ${x.lowerBound ? "≥" : ""}${x.g131}, audible ${x.audiblePct}%, sent ${x.sentDbfs} dBFS, ${x.seconds} s`;
  console.log(`${r.name}\n  far end only: ${f(r.farOnly)}\n  you talking:  ${f(r.talkOver)}${r.drift ? `\n  clocks gap ${r.drift.gapPpm} ppm, echo path slope ${r.drift.echoPathSlopeMsPerMin} ms/min, spread ${r.drift.echoPathSpreadMs} ms` : ""}`);
}
