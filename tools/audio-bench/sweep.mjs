#!/usr/bin/env node
// Offline tuning from one call audio dump: replays the recorded mic and reference through the exact processing
// the patched WebKit unit runs (apm-replay-webkit, built by Spike/CallAudio/webkit/build-replay.sh) with other
// settings, scores every variant by the guest's ear (dumpscore.mjs), and prints the best setting as the
// environment variables to start Browsa WebKit Spike with. Nothing is played or recorded.
//
//   node tools/audio-bench/sweep.mjs <dump folder> [--minutes 10] [--offsets -40:40:5] [--out <folder>] [--quick]
//
// 1. Scores what was sent live (sent.wav), and checks that replaying with the recorded settings gives it back.
// 2. Sweeps the reference offset (later +, earlier -) with the recorded gain and noise settings.
// 3. At the best offset: auto gain off, gain limits 20/40 dB, noise ceiling -50/-70 dBFS, noise suppression 1/3.
// Offsets are relative to the dump's reference, which already carries the recorded BROWSA_CALL_AUDIO_REF_OFFSET_MS;
// the printed setting adds the two. Writes <out>/sweep.json and report.txt (default: a sweep-<time> folder next to
// the dump when that is under derived/audio-bench, else in derived/audio-bench), report.html with the offset curve and
// clips (live-/best-guest-hears.m4a, +30 dB versions) over the far-only stretches.
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { RATE, db, power, writeWavFloat, readWav } from "./analyze.mjs";
import { loadDump, echoLag, detectStretches, scoreSent, rank, describe, m4a, joined } from "./dumpscore.mjs";
import { writeSweepHtml } from "./htmlreport.mjs";

const run = promisify(execFile);
const REPLAY = process.env.APM_REPLAY_WEBKIT || path.join(os.homedir(), "Developer/Browsa/derived/audio-lab/apm-replay-webkit");
const BENCH = path.join(os.homedir(), "Developer/Browsa/derived/audio-bench");

export async function sweep(dir, opt = {}) {
  const t0 = Date.now();
  const d = loadDump(dir);
  const limit = Math.floor(parseFloat(opt.minutes ?? 10) * 60 * RATE);
  const crop = (x) => (x && x.length > limit ? x.subarray(0, limit) : x);
  const raw = crop(d.raw), ref = crop(d.ref), live = crop(d.sent);
  const rec = { referenceOffsetMs: 0, agc: true, agcMaxDb: 30, agcNoiseDbfs: -60, ns: 2, warmup: false, gatedGain: false, ...(d.meta.settings || {}) };
  const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
  const out = opt.out || (path.resolve(dir).startsWith(BENCH) ? `${path.resolve(dir).replace(/\/$/, "")}-sweep-${stamp}` : path.join(BENCH, `sweep-${stamp}`));
  fs.mkdirSync(out, { recursive: true });
  const work = path.join(out, "work");
  fs.mkdirSync(work, { recursive: true });
  const rawPath = path.join(work, "raw.wav"), refPath = path.join(work, "ref.wav");
  writeWavFloat(rawPath, [raw], RATE);
  writeWavFloat(refPath, [ref], RATE);

  const lag = echoLag(raw, ref);
  const st = detectStretches(raw, ref, lag.lag);
  const score = (x) => { const s = scoreSent(x, ref, raw, st, lag.lag); return { ...s, rank: rank(s) }; };
  const result = { dump: path.resolve(dir), dumpMode: d.meta.mode || null, engine: REPLAY, recorded: rec, minutesUsed: +(raw.length / RATE / 60).toFixed(2), echoLagMs: lag.ms, echoLagFound: lag.found,
    stretches: { farOnlySec: +(st.far.reduce((s, [a, z]) => s + z - a, 0) / RATE).toFixed(1), counts: st.counts }, variants: [] };

  if (live) { result.live = score(live); delete result.live.blocks; }

  // One replay: options relative to the recorded settings.
  const variant = async (label, o) => {
    const s = { ...rec, ...o, shiftMs: o.shiftMs ?? 0 };
    const file = path.join(work, `${result.variants.length}-${Math.random().toString(36).slice(2, 7)}.wav`);
    const cli = ["--raw", rawPath, "--ref", refPath, "--out", file, "--ref-shift-ms", String(s.shiftMs), "--agc", s.agc ? "1" : "0",
      "--agc-max-db", String(s.agcMaxDb), "--agc-noise-dbfs", String(s.agcNoiseDbfs), "--ns", s.ns < 0 ? "off" : String(s.ns),
      "--warmup", s.warmup ? "1" : "0", "--gated-gain", s.gatedGain ? "1" : "0"];
    await run(REPLAY, cli);
    const x = readWav(file).channels[0];
    const sc = score(x);
    delete sc.blocks;
    const v = { label, settings: { referenceOffsetMs: rec.referenceOffsetMs + s.shiftMs, agc: s.agc, agcMaxDb: s.agcMaxDb, agcNoiseDbfs: s.agcNoiseDbfs, ns: s.ns, warmup: s.warmup, gatedGain: s.gatedGain }, shiftMs: s.shiftMs, score: sc, file };
    result.variants.push(v);
    return { v, x };
  };

  // Does the replay give back what was sent live? (Only expected for dumps from the WebKit unit itself.)
  const base = await variant("recorded settings", {});
  if (live) {
    const n = Math.min(live.length, base.x.length), diff = new Float32Array(n);
    for (let i = 0; i < n; i++) diff[i] = live[i] - base.x[i];
    result.replayVsLiveDb = +(db(power(diff, 0, n)) - db(power(live, 0, n))).toFixed(1);
  }

  const [lo, hi, step] = (opt.offsets || "-40:40:5").split(":").map(Number);
  const offsets = [];
  for (let o = lo; o <= hi + 1e-9; o += step) if (Math.abs(o) > 1e-9) offsets.push(o);
  const pool = async (items, fn, width = Math.max(2, Math.min(8, os.cpus().length - 2))) => {
    const res = []; let i = 0;
    await Promise.all(Array.from({ length: width }, async () => { while (i < items.length) { const k = i++; res[k] = await fn(items[k]); } }));
    return res;
  };
  await pool(offsets, (o) => variant(`reference ${o > 0 ? "+" : ""}${o} ms`, { shiftMs: o }));
  const better = (a, b) => (b == null || (a.score.rank ?? -1e9) > (b.score.rank ?? -1e9) + 0.05 ? a : b);
  const byOffset = result.variants.slice().sort((a, b) => a.shiftMs - b.shiftMs);
  let bestOffset = null;
  for (const v of byOffset) bestOffset = better(v, bestOffset);
  // Prefer the smaller shift among near ties (within 0.5): the canceller finds its own delay over a range.
  const tie = byOffset.filter((v) => (v.score.rank ?? -1e9) >= (bestOffset.score.rank ?? -1e9) - 0.5).sort((a, b) => Math.abs(a.shiftMs) - Math.abs(b.shiftMs))[0];
  if (tie) bestOffset = tie;
  const shiftMs = bestOffset.shiftMs;

  if (!opt.quick) {
    const tries = [
      ["auto gain off", { agc: false }],
      ["gain limit 20 dB", { agc: true, agcMaxDb: 20 }],
      ["gain limit 40 dB", { agc: true, agcMaxDb: 40 }],
      ["gain noise ceiling -50 dBFS", { agc: true, agcNoiseDbfs: -50 }],
      ["gain noise ceiling -70 dBFS", { agc: true, agcNoiseDbfs: -70 }],
      ["noise suppression moderate", { ns: 1 }],
      ["noise suppression very high", { ns: 3 }],
      ["warm-up + gain only while talking", { warmup: true, gatedGain: true, agc: false }],
      ["no warm-up, no gated gain (WebRTC gain)", { warmup: false, gatedGain: false, agc: true }],
    ].filter(([, o]) => Object.entries(o).some(([k, v]) => rec[k] !== v));
    await pool(tries, ([label, o]) => variant(`${label}, reference ${shiftMs > 0 ? "+" : ""}${shiftMs} ms`, { shiftMs, ...o }));
  }
  let best = null;
  for (const v of result.variants) best = better(v, best);
  // Ties (within 0.5: about one 200 ms block of audible echo in a minute) go to the fewest changes, then the higher rank, then the smallest shift.
  const changes = (v) => Object.keys(v.settings).filter((k) => v.settings[k] !== rec[k]).length;
  const near = result.variants.filter((v) => (v.score.rank ?? -1e9) >= (best.score.rank ?? -1e9) - 0.5).sort((a, b) => changes(a) - changes(b) || (b.score.rank ?? -1e9) - (a.score.rank ?? -1e9) || Math.abs(a.shiftMs) - Math.abs(b.shiftMs));
  best = near[0] || best;
  result.best = best;
  result.bestEnv = envFor(best.settings);
  result.seconds = Math.round((Date.now() - t0) / 1000);

  // Keep the replays that matter, drop the rest.
  for (const v of result.variants) {
    if (v === best) { fs.renameSync(v.file, path.join(out, "best-sent.wav")); v.file = path.join(out, "best-sent.wav"); }
    else if (v === base.v) { fs.renameSync(v.file, path.join(out, "replay-recorded-sent.wav")); v.file = path.join(out, "replay-recorded-sent.wav"); }
    else { fs.rmSync(v.file, { force: true }); v.file = null; }
  }
  fs.rmSync(work, { recursive: true, force: true });
  // Clips over the far-only stretches: what the guest heard live, and with the best setting.
  if (st.far.length) {
    const bestSent = readWav(best.file).channels[0];
    try {
      if (live) { m4a(joined(live, st.far), path.join(out, "live-guest-hears.m4a")); m4a(joined(live, st.far, 10 ** 1.5), path.join(out, "live-guest-hears-plus30dB.m4a")); }
      m4a(joined(bestSent, st.far), path.join(out, "best-guest-hears.m4a"));
      m4a(joined(bestSent, st.far, 10 ** 1.5), path.join(out, "best-guest-hears-plus30dB.m4a"));
    } catch (e) { console.error(`clips: ${e.message}`); }
  }
  result.out = out;
  result.line = summaryLine(result);
  fs.writeFileSync(path.join(out, "sweep.json"), JSON.stringify(result, null, 2));
  fs.writeFileSync(path.join(out, "report.txt"), report(result));
  writeSweepHtml(result, out);
  return result;
}

export function envFor(s) {
  const e = [];
  if (s.referenceOffsetMs) e.push(`BROWSA_CALL_AUDIO_REF_OFFSET_MS=${s.referenceOffsetMs}`);
  if (!s.agc && s.gatedGain === false) e.push("BROWSA_CALL_AUDIO_AGC=0");
  if (s.agc && s.gatedGain) e.push("BROWSA_CALL_AUDIO_AGC=1");
  if (s.agc && s.agcMaxDb !== 30) e.push(`BROWSA_CALL_AUDIO_AGC_MAX_DB=${s.agcMaxDb}`);
  if (s.agc && s.agcNoiseDbfs !== -60) e.push(`BROWSA_CALL_AUDIO_AGC_NOISE_DBFS=${s.agcNoiseDbfs}`);
  if (s.ns !== 2) e.push(`BROWSA_CALL_AUDIO_NS=${s.ns < 0 ? "off" : s.ns}`);
  if (s.warmup === false) e.push("BROWSA_CALL_AUDIO_WARMUP=0");
  if (s.gatedGain === false) e.push("BROWSA_CALL_AUDIO_GATED_GAIN=0");
  return e.length ? e.join(" ") : "(defaults)";
}

const f = (s) => (s?.margin == null ? "n/a" : `f ${s.marginIsLowerBound ? "≥" : ""}${s.margin}${s.audiblePct != null ? ` (${s.audiblePct}% audible)` : ""}${s.sendLevelDb != null ? `, send ${s.sendLevelDb} dBFS` : ""}`);
function summaryLine(r) {
  const cur = r.live ? f(r.live) : `${f(r.variants[0].score)} (replay)`;
  return `current: ${cur} | best: ${r.bestEnv} (${r.best.label}) | at best: ${f(r.best.score)}`;
}
function report(r) {
  const rows = r.variants.slice().sort((a, b) => (b.score.rank ?? -1e9) - (a.score.rank ?? -1e9))
    .map((v) => `${String(v.score.rank ?? "n/a").padStart(6)}  ${v.label.padEnd(48)} ${describe(v.score)}`);
  return [
    `Sweep of ${r.dump} (first ${r.minutesUsed} min) with ${path.basename(r.engine)}, ${r.seconds} s`,
    `Recorded settings: ${JSON.stringify(r.recorded)}`,
    `Echo path ${r.echoLagMs} ms${r.echoLagFound ? "" : " (no clear echo found)"}; far-only ${r.stretches.farOnlySec} s; 2 s blocks: ${JSON.stringify(r.stretches.counts)}`,
    r.live ? `Live (sent.wav): ${describe(r.live)}` : "No sent.wav",
    r.replayVsLiveDb != null ? `Replay with recorded settings vs live: difference ${r.replayVsLiveDb} dB below the live signal (about -30 or lower: the replay reproduces the call)` : "",
    "",
    "rank = G.131 margin capped at 20, less 0.25 per % audible, less a send level penalty; higher is better",
    ...rows,
    "",
    r.line,
    `Start the spike with: ${r.bestEnv === "(defaults)" ? "no extra variables" : r.bestEnv} (e.g. ${r.bestEnv === "(defaults)" ? "" : r.bestEnv + " "}~/Developer/Browsa/derived/webkit-spike/run.sh)`,
    "",
  ].join("\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2), args = { minutes: "10", offsets: "-40:40:5" };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) { positional.push(argv[i]); continue; }
    const k = argv[i].slice(2), v = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "1";
    args[k] = v;
  }
  const dumpDir = positional[0];
  if (!dumpDir) { console.error("usage: sweep.mjs <dump folder> [--minutes 10] [--offsets -40:40:5] [--out folder] [--quick]"); process.exit(1); }
  if (!fs.existsSync(REPLAY)) { console.error(`no ${REPLAY}: run Spike/CallAudio/webkit/build-replay.sh`); process.exit(1); }
  const r = await sweep(dumpDir, { minutes: args.minutes, offsets: args.offsets, out: args.out, quick: args.quick === "1" });
  console.log(fs.readFileSync(path.join(r.out, "report.txt"), "utf8"));
  console.log(r.line);
}
