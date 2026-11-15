#!/usr/bin/env node
// After a real call in Browsa WebKit Spike: judges the call by the guest's ear from the unit's debug dump.
//   node tools/audio-bench/aftercall.mjs [dump folder] [--sweep] [--minutes 10]
// With no folder, takes the newest browsa-call-audio-* the spike's GPU process wrote (its private cache and temp
// folders, where BROWSA_CALL_AUDIO_DUMP=1 puts them). Copies the dump to
// ~/Developer/Browsa/derived/audio-bench/call-<time>/ and writes there:
//   report.html                      scores and clips, playable in place (and the sweep, with --sweep)
//   report.txt, score.json           the scores (see dumpscore.mjs for which figures a real call supports)
//   guest-hears.m4a                  what the other side heard of their own voice: sent audio over the far-only stretches
//   guest-hears-plus30dB.m4a         the same, 30 dB louder, to hear faint leftovers
//   you-sent.m4a                     your voice as sent, over the stretches where only you talked
// --sweep then runs sweep.mjs on the dump (offline replays with other settings) and prints the best setting.
// Recordings of your room: they stay in derived/, never in git.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { RATE } from "./analyze.mjs";
import { loadDump, echoLag, detectStretches, scoreSent, rank, describe, m4a, joined } from "./dumpscore.mjs";
import { writeCallHtml } from "./htmlreport.mjs";

const BENCH = path.join(os.homedir(), "Developer/Browsa/derived/audio-bench");
const SPIKE_PROCESS = "com.apple.WebKit.GPU+com.orriginal.browsa.webkitspike";

export function findDumps() {
  const roots = [];
  for (const which of ["DARWIN_USER_CACHE_DIR", "DARWIN_USER_TEMP_DIR"]) {
    try { roots.push(path.join(execFileSync("getconf", [which], { encoding: "utf8" }).trim(), SPIKE_PROCESS)); } catch {}
  }
  const found = [];
  for (const r of roots) {
    let names = [];
    try { names = fs.readdirSync(r); } catch { continue; }
    for (const n of names) if (n.startsWith("browsa-call-audio-")) {
      const dir = path.join(r, n);
      try {
        let seconds = null;
        try { seconds = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")).capturedSeconds ?? null; } catch {}
        // A unit WebKit set up and dropped straight away leaves a dump of a fraction of a second: skip those.
        if (seconds != null && seconds < 5) continue;
        found.push({ dir, mtime: fs.statSync(path.join(dir, "raw.wav")).mtimeMs, seconds });
      } catch {}
    }
  }
  return found.sort((a, b) => b.mtime - a.mtime);
}

export async function afterCall(src, opt = {}) {
  const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
  const out = path.join(BENCH, `call-${stamp}`), dumpCopy = path.join(out, "dump");
  fs.mkdirSync(dumpCopy, { recursive: true });
  for (const f of ["raw.wav", "ref.wav", "sent.wav", "meta.json"]) if (fs.existsSync(path.join(src, f))) fs.copyFileSync(path.join(src, f), path.join(dumpCopy, f));

  const d = loadDump(dumpCopy);
  if (!d.sent) throw new Error(`${src}: no sent.wav`);
  if (d.raw.length < 10 * RATE) throw new Error(`${src}: only ${(d.raw.length / RATE).toFixed(1)} s of audio, too short to score`);
  const lag = echoLag(d.raw, d.ref);
  const st = detectStretches(d.raw, d.ref, lag.lag);
  const s = scoreSent(d.sent, d.ref, d.raw, st, lag.lag);
  const blocks = s.blocks || [];
  delete s.blocks;
  const minutes = d.raw.length / RATE / 60;
  const mixedSec = ((st.counts.mixed || 0) * 0.5);

  if (st.far.length) {
    m4a(joined(d.sent, st.far), path.join(out, "guest-hears.m4a"));
    m4a(joined(d.sent, st.far, 10 ** (30 / 20)), path.join(out, "guest-hears-plus30dB.m4a"));
  }
  if (st.near.length) m4a(joined(d.sent, st.near, 1, 60), path.join(out, "you-sent.m4a"));

  // The worst moments, as call times (seconds into the dump), for listening back.
  const t = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, "0")}`;
  let acc = 0;
  const toCall = st.far.map(([a, z]) => { const m = { from: acc, to: acc + (z - a) / RATE, at: a / RATE }; acc = m.to; return m; });
  const callTime = (sec) => { const m = toCall.find((m) => sec >= m.from && sec < m.to); return m ? m.at + sec - m.from : null; };
  const worst = blocks.filter((b) => b.audible).sort((p, q) => p.lossDb - q.lossDb).slice(0, 5).map((b) => ({ ...b, callTime: callTime(b.t) }));

  const score = { dump: src, copiedTo: dumpCopy, minutes: +minutes.toFixed(1), complete: d.meta.complete ?? null, settings: d.meta.settings || null,
    droppedFrames: d.meta.droppedFrames ?? null, echoLagMs: lag.ms, ...s, rank: rank(s), mixedSec, worst };
  fs.writeFileSync(path.join(out, "score.json"), JSON.stringify(score, null, 2));
  const lines = [
    `Call of ${minutes.toFixed(1)} min, dump ${src}${d.meta.complete === false ? " (not closed cleanly: the call's mic never stopped, or the app quit; the files are valid up to the last half second written)" : ""}`,
    `Settings: ${JSON.stringify(d.meta.settings || "unknown (older dump)")}${d.meta.droppedFrames ? `; ${d.meta.droppedFrames} frames dropped by the writer` : ""}`,
    `Echo path ${lag.ms} ms${lag.found ? "" : " (no clear echo in the mic: speakers quiet, or headphones)"}`,
    "",
    `Guest's ear: ${describe(s)}`,
    "",
    "What these mean in a real call (no known talker):",
    `  far-only ${s.farOnlySec} s: the other side talking, you quiet. All echo figures come from here only.`,
    `  you-only ${s.nearOnlySec} s: your send level ${s.sendLevelDb ?? "n/a"} dBFS (nominal about -26), voice kept ${s.voiceKeptDb ?? "n/a"} dB against the raw mic.`,
    `  both or unclear ${mixedSec} s: not scored. Talk-over and gain pumping need a known talker: use the bench for those.`,
    `  room as sent ${s.floorDb} dBFS.`,
    worst.length ? `Worst moments (call time, echo loss): ${worst.map((w) => `${w.callTime != null ? t(w.callTime) : "?"} ${w.lossDb} dB`).join(", ")}` : "No audible echo moments.",
    "",
    `Clips in ${out}: guest-hears.m4a, guest-hears-plus30dB.m4a, you-sent.m4a`,
  ];
  let sweepResult = null;
  if (opt.sweep) {
    const { sweep } = await import("./sweep.mjs");
    const r = await sweep(dumpCopy, { minutes: opt.minutes ?? 10, out: path.join(out, "sweep") });
    sweepResult = r;
    lines.push("", `Sweep (first ${r.minutesUsed} min, ${r.seconds} s): ${r.line}`, `Details: ${path.join(out, "sweep/report.txt")}`);
    if (r.replayVsLiveDb != null) lines.push(`Replay check: recorded settings replayed ${r.replayVsLiveDb} dB from what was sent live${r.replayVsLiveDb > -20 ? " (NOT a faithful replay: treat the sweep with care)" : " (faithful)"}`);
  }
  writeCallHtml(score, out, sweepResult);
  lines.push(`Report: ${path.join(out, "report.html")}`);
  fs.writeFileSync(path.join(out, "report.txt"), lines.join("\n") + "\n");
  return { out, lines, score };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2), opt = {};
  let src = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--sweep") opt.sweep = true;
    else if (argv[i] === "--minutes") opt.minutes = argv[++i];
    else src = argv[i];
  }
  if (!src) {
    const all = findDumps();
    if (!all.length) { console.error(`No dump found in the spike's GPU process folders (${SPIKE_PROCESS}). Was it started with BROWSA_CALL_AUDIO_DUMP=1?`); process.exit(1); }
    src = all[0].dir;
    if (all.length > 1) console.log(`Newest of ${all.length} dumps: ${src}`);
  }
  const r = await afterCall(src, opt);
  console.log(r.lines.join("\n"));
}
