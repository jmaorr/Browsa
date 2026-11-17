#!/usr/bin/env node
// Offline tuning: runs native recordings (raw mic + the exact reference) through WebRTC's processing again
// with different settings (apm-replay, no audio devices), then scores every variant with the bench analysis.
//   node tools/audio-bench/replay.mjs <run folder> [subject ids, default every native one with raw.wav + ref.wav]
// Writes a new run folder <run folder>-replay-<time> with report.html. Nothing is played or recorded.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPLAY = path.join(os.homedir(), "Developer/Browsa/derived/audio-lab/apm-replay");
const [runDir, only] = process.argv.slice(2);
if (!runDir) { console.error("usage: replay.mjs <run folder> [subject ids]"); process.exit(1); }
const src = JSON.parse(fs.readFileSync(path.join(runDir, "results.json"), "utf8"));

// What to try. Each is apm-replay's options.
const VARIANTS = [
  ["as recorded settings, no auto gain", []],
  ["auto gain (3 dB/s, noise cap -50)", ["--gain"]],
  ["auto gain, slower (1.5 dB/s, noise cap -60)", ["--gain", "--gain-speed", "1.5", "--gain-noise", "-60"]],
  ["auto gain + noise suppression very high", ["--gain", "--ns", "3"]],
  ["auto gain + noise suppression moderate", ["--gain", "--ns", "1"]],
  ["no noise suppression, no auto gain", ["--no-ns"]],
  ["reference 10 ms early", ["--ref-shift-ms", "-10"]],
  ["reference 10 ms late", ["--ref-shift-ms", "10"]],
  ["reference 30 ms late", ["--ref-shift-ms", "30"]],
];

const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
const out = `${runDir.replace(/\/$/, "")}-replay-${stamp}`;
fs.mkdirSync(out, { recursive: true });
const subjects = [];
for (const s of src.subjects) {
  if (s.status !== "ok" || (only && !only.split(",").includes(s.id))) continue;
  const raw = path.join(s.dir, "raw.wav"), ref = path.join(s.dir, "ref.wav");
  if (!fs.existsSync(raw) || !fs.existsSync(ref)) continue;
  for (const [label, opts] of VARIANTS) {
    const id = `${s.id}--${label.replace(/[^a-z0-9]+/gi, "-").toLowerCase().replace(/-$/, "")}`, dir = path.join(out, id);
    fs.mkdirSync(dir, { recursive: true });
    const stats = JSON.parse(execFileSync(REPLAY, ["--raw", raw, "--ref", ref, "--out", path.join(dir, "sent.wav"), ...opts], { encoding: "utf8" }));
    fs.copyFileSync(raw, path.join(dir, "raw.wav"));
    if (fs.existsSync(path.join(s.dir, "channels.wav"))) fs.copyFileSync(path.join(s.dir, "channels.wav"), path.join(dir, "channels.wav"));
    const meta = { ...(s.meta || {}), replayOf: s.dir, replayOptions: opts, erle: stats.erle, delayMs: stats.delayMs > 0 ? stats.delayMs : s.meta?.delayMs, mode: "webrtc" };
    fs.writeFileSync(path.join(dir, "meta.json"), JSON.stringify(meta, null, 2));
    subjects.push({ id, name: `${s.name.replace(/^.*@/, "Replay of " + s.id.replace(/-v\d+$/, "") + " @")}: ${label}`, volume: s.volume, kind: "native", mode: "webrtc", status: "ok", dir, meta });
    console.log(`${id}: done`);
  }
}
fs.writeFileSync(path.join(out, "results.json"), JSON.stringify({ ...src, startedAt: `${src.startedAt} (replayed ${stamp})`,
  description: `Offline replays of ${path.basename(runDir)}: the recorded mic and reference through WebRTC's processing again, with other settings. Nothing played. ${src.description}`, subjects }, null, 2));
execFileSync(process.execPath, [path.join(HERE, "bench.mjs"), "--reanalyze", out], { stdio: "inherit" });
