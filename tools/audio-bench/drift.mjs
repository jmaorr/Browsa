#!/usr/bin/env node
// Clock drift between the speakers and the microphone over a run, from a unit dump (raw.wav, ref.wav, meta.json).
//   node tools/audio-bench/drift.mjs <dump folder>
// Two views:
// - the clocks: the unit's own estimates (meta.json, host-time based) of each device's real rate against its
//   nominal one, in parts per million, and the gap between them. 10 ppm is 0.6 ms a minute.
// - the echo path: the delay from the reference (what played) to the microphone (raw) in 10 s windows, measured
//   from the recordings. The unit reads the reference in host time, so this should stay put however the clocks
//   drift; a slope here is drift the canceller has to chase.
import fs from "node:fs";
import path from "node:path";
import { RATE, readWav, findLag, coherentPower, power, db } from "./analyze.mjs";

export function driftReport(dir) {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));
  const raw = readWav(path.join(dir, "raw.wav")).channels[0], ref = readWav(path.join(dir, "ref.wav")).channels[0];
  const ppm = (rate, nominal) => (rate && nominal ? +((rate / nominal - 1) * 1e6).toFixed(1) : null);
  const speakerPpm = ppm(meta.speakerClockRate, meta.webkitSpeakerFormat?.rate);
  const micPpm = ppm(meta.micClockRate, meta.inputRate);
  const clocks = { speakerPpm, micPpm, gapPpm: speakerPpm != null && micPpm != null ? +(speakerPpm - micPpm).toFixed(1) : null,
    referenceResyncs: meta.referenceResyncs ?? null, referenceMisses: meta.referenceMisses ?? null };

  // Echo path per 10 s window with enough far end in it; 0.25 ms steps around the coarse best.
  const win = 10 * RATE, series = [];
  const refLevel = db(power(ref, 0, ref.length));
  for (let a = 0; a + win <= raw.length; a += win) {
    if (db(power(ref, a, a + win)) < refLevel - 15) continue;
    const coarse = findLag(raw, ref, a, a + win, -100, 400);
    if (coarse.fraction < 0.05) continue;
    let best = coarse;
    for (let ms = coarse.ms - 3; ms <= coarse.ms + 3; ms += 0.25) {
      const lag = Math.round((ms * RATE) / 1000), r = coherentPower(raw, ref, a, a + win, lag);
      if (r.power > best.power) best = { lag, ms, ...r };
    }
    series.push({ t: +(a / RATE).toFixed(0), ms: +best.ms.toFixed(2), fraction: +best.fraction.toFixed(2) });
  }
  let slope = null, span = null;
  if (series.length >= 3) {
    const n = series.length, mt = series.reduce((s, p) => s + p.t, 0) / n, mm = series.reduce((s, p) => s + p.ms, 0) / n;
    const sxy = series.reduce((s, p) => s + (p.t - mt) * (p.ms - mm), 0), sxx = series.reduce((s, p) => s + (p.t - mt) ** 2, 0);
    slope = sxx > 0 ? +((sxy / sxx) * 60).toFixed(2) : null;
    span = +(Math.max(...series.map((p) => p.ms)) - Math.min(...series.map((p) => p.ms))).toFixed(2);
  }
  return { seconds: meta.capturedSeconds ?? +(raw.length / RATE).toFixed(1), clocks, echoPath: { windows: series, slopeMsPerMin: slope, spanMs: span } };
}

export function driftText(r) {
  const c = r.clocks, e = r.echoPath;
  return [`clocks over ${r.seconds} s: speakers ${c.speakerPpm ?? "–"} ppm, microphone ${c.micPpm ?? "–"} ppm, gap ${c.gapPpm ?? "–"} ppm` +
    ` (${c.gapPpm != null ? (Math.abs(c.gapPpm) * 0.06).toFixed(2) : "–"} ms a minute), reference resyncs ${c.referenceResyncs ?? "–"}, misses ${c.referenceMisses ?? "–"}`,
    `echo path: ${e.windows.length} windows, ${e.windows.length ? e.windows[0].ms : "–"} to ${e.windows.length ? e.windows.at(-1).ms : "–"} ms, slope ${e.slopeMsPerMin ?? "–"} ms/min, spread ${e.spanMs ?? "–"} ms`].join("\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (!process.argv[2]) { console.error("usage: drift.mjs <dump folder>"); process.exit(1); }
  const r = driftReport(process.argv[2]);
  console.log(driftText(r));
  console.log(JSON.stringify(r.echoPath.windows));
}
