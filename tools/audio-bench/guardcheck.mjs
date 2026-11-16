#!/usr/bin/env node
// Checks Browsa's post-processing stage (Spike/CallAudio/core/CallGuard.h: join warm-up, gain only while you talk)
// on a call dump, offline: replays it with and without, and compares.
//   node tools/audio-bench/guardcheck.mjs <dump folder> [--windows 0:2,16.5:17.5] [--minutes 10]
// Per variant: echo loss in each window (far end's level against the far-end-correlated level sent), the overall
// guest's-ear score on far-end-only stretches, your send level, how much of the start of each of your stretches
// came through (first 300 ms against the rest), gain pumping (spread of sent-minus-raw level over 1 s windows while
// only you talk) and the room as sent. Nothing played.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { RATE, db, power, coherentPower, readWav, writeWavFloat } from "./analyze.mjs";
import { loadDump, echoLag, detectStretches, scoreSent } from "./dumpscore.mjs";

const REPLAY = process.env.BROWSA_REPLAY || path.join(os.homedir(), "Developer/Browsa/derived/audio-lab/apm-replay-webkit");

export function guardCheck(dir, opt = {}) {
  // BROWSA_GUARD="name=value name=value": CallGuard settings to try (apm-replay-webkit --guard).
  const guardArgs = (process.env.BROWSA_GUARD || "").split(/\s+/).filter(Boolean).flatMap((kv) => ["--guard", kv]);
  const d = loadDump(dir);
  const limit = Math.floor((opt.minutes ?? 10) * 60 * RATE);
  const raw = d.raw.subarray(0, limit), ref = d.ref.subarray(0, limit), live = d.sent ? d.sent.subarray(0, limit) : null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "guardcheck-"));
  const rawPath = path.join(tmp, "raw.wav"), refPath = path.join(tmp, "ref.wav");
  writeWavFloat(rawPath, [raw], RATE); writeWavFloat(refPath, [ref], RATE);
  const lag = echoLag(raw, ref), st = detectStretches(raw, ref, lag.lag);
  const s = d.meta.settings || {};
  // The baseline is WebRTC's own gain and nothing after it (the unit before CallGuard), whatever the dump ran.
  const base = ["--agc", "1", "--agc-max-db", String(s.agcMaxDb ?? 30), "--agc-noise-dbfs", String(s.agcNoiseDbfs ?? -60), "--ns", String(s.ns ?? 2)];
  const variants = [
    ...(live ? [["live (as sent)", null]] : []),
    ["replay, WebRTC gain (before CallGuard)", base],
    ["+ warm-up", [...base, "--warmup", "1"]],
    ["gain only while talking", [...base, "--gated-gain", "1", ...guardArgs]],
    ["warm-up + gain only while talking", [...base, "--warmup", "1", "--gated-gain", "1", ...guardArgs]],
  ];
  const windows = (opt.windows || "0:2").split(",").map((w) => w.split(":").map(Number));
  const rows = [];
  try {
    for (const [label, args] of variants) {
      let x = live, stats = null;
      if (args) {
        const out = path.join(tmp, "sent.wav");
        stats = JSON.parse(execFileSync(REPLAY, ["--raw", rawPath, "--ref", refPath, "--out", out, ...args], { encoding: "utf8" }));
        x = readWav(out).channels[0];
      }
      const win = windows.map(([a, b]) => {
        const c = coherentPower(x, ref, a * RATE, b * RATE, lag.lag);
        const echo = Math.max(db(c.power), db(c.limit));
        return { window: `${a}-${b} s`, lossDb: +(db(power(ref, a * RATE, b * RATE)) - echo).toFixed(1), atLimit: db(c.power) < db(c.limit) };
      });
      const sc = scoreSent(x, ref, raw, st, lag.lag);
      // Onsets: first 300 ms of each you-only stretch (the stretch starts 0.75 s into its block, so look from there).
      const onsets = st.near.map(([a, z]) => {
        const o = activeDb(x, a, a + 0.3 * RATE) - activeDb(raw, a, a + 0.3 * RATE), rest = activeDb(x, a + 0.3 * RATE, z) - activeDb(raw, a + 0.3 * RATE, z);
        return o - rest;
      }).filter(isFinite);
      const diffs = [];
      for (const [a, z] of st.near) for (let w = a; w + RATE <= z; w += RATE) diffs.push(db(power(x, w, w + RATE)) - db(power(raw, w, w + RATE)));
      const mean = diffs.reduce((p, q) => p + q, 0) / Math.max(1, diffs.length);
      rows.push({ label, windows: win, margin: sc.margin, marginIsLowerBound: sc.marginIsLowerBound, audiblePct: sc.audiblePct, echoLossDb: sc.echoLossDb,
        sendLevelDb: sc.sendLevelDb, floorDb: sc.floorDb,
        onsetDb: onsets.length ? +(onsets.reduce((p, q) => p + q, 0) / onsets.length).toFixed(1) : null,
        pumpingDb: diffs.length > 2 ? +Math.sqrt(diffs.reduce((p, q) => p + (q - mean) ** 2, 0) / diffs.length).toFixed(1) : null, stats });
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  return { dump: dir, echoLagMs: lag.ms, farOnlySec: +(st.far.reduce((p, [a, z]) => p + z - a, 0) / RATE).toFixed(1), nearOnlySec: +(st.near.reduce((p, [a, z]) => p + z - a, 0) / RATE).toFixed(1), rows };
}
function activeDb(x, a, b) { return db(power(x, a, b)); }

export function table(r) {
  const head = ["variant".padEnd(36), ...r.rows[0].windows.map((w) => `loss ${w.window}`.padStart(16)), "f".padStart(7), "audible".padStart(8), "send".padStart(7), "floor".padStart(7), "onset".padStart(7), "pump".padStart(6)].join("");
  const lines = r.rows.map((x) => [x.label.padEnd(36), ...x.windows.map((w) => `${w.atLimit ? "≥" : ""}${w.lossDb}`.padStart(16)),
    `${x.marginIsLowerBound ? "≥" : ""}${x.margin ?? "–"}`.padStart(7), `${x.audiblePct ?? "–"}%`.padStart(8), `${x.sendLevelDb ?? "–"}`.padStart(7), `${x.floorDb ?? "–"}`.padStart(7),
    `${x.onsetDb ?? "–"}`.padStart(7), `${x.pumpingDb ?? "–"}`.padStart(6)].join(""));
  return [`${r.dump}  (echo path ${r.echoLagMs} ms, far-only ${r.farOnlySec} s, you-only ${r.nearOnlySec} s)`, head, ...lines,
    "loss: dB, higher is better (≥: at the measurement limit). f: G.131 margin. onset: first 300 ms of your stretches against the rest, dB (0 = not clipped). pump: dB spread."].join("\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2), opt = {};
  let dir = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--windows") opt.windows = argv[++i];
    else if (argv[i] === "--minutes") opt.minutes = parseFloat(argv[++i]);
    else dir = argv[i];
  }
  if (!dir) { console.error("usage: guardcheck.mjs <dump folder> [--windows 0:2,16.5:17.5] [--minutes 10]"); process.exit(1); }
  const r = guardCheck(dir, opt);
  console.log(table(r));
  for (const x of r.rows) if (x.stats) console.log(`  ${x.label}: ${JSON.stringify(x.stats)}`);
}
