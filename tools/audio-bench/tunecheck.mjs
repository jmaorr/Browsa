#!/usr/bin/env node
// Tuning CallGuard (Spike/CallAudio/core/CallGuard.h) against a bench run, with the bench's own analysis: replays a
// recorded mic + reference (a unit dump, or a native run's raw.wav/ref.wav) through apm-replay-webkit with the
// given CallGuard settings, puts the result in place of that subject's sent audio in a copy of the run, and
// re-analyses it (known far end and talker: guest's ear, talk-over, send level, gain pumping). Nothing played.
//   node tunecheck.mjs <bench run folder> <subject id> <folder with raw.wav + ref.wav> [--scale dB]
//                      [--guard name=value ...] [--plain]   (--plain: WebRTC's gain, no CallGuard)
// --scale changes the mic level before replay (a hotter or quieter mic than the one recorded).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { RATE, readWav, writeWavFloat } from "./analyze.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPLAY = path.join(os.homedir(), "Developer/Browsa/derived/audio-lab/apm-replay-webkit");

export function tuneCheck(runDir, subjectId, srcDir, opt = {}) {
  const results = JSON.parse(fs.readFileSync(path.join(runDir, "results.json"), "utf8"));
  const sub = results.subjects.find((s) => s.id === subjectId);
  if (!sub) throw new Error(`no subject ${subjectId} in ${runDir}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tunecheck-"));
  try {
    const dir = path.join(tmp, subjectId);
    fs.mkdirSync(dir);
    for (const f of fs.readdirSync(sub.dir)) {
      const p = path.join(sub.dir, f);
      if (fs.statSync(p).isFile() && !/^(sent|raw|ref|guest-hears.*)\.wav$/.test(f)) fs.copyFileSync(p, path.join(dir, f));
    }
    const raw = readWav(path.join(srcDir, "raw.wav")).channels[0];
    const g = 10 ** ((opt.scale || 0) / 20);
    const scaled = raw.map((v) => Math.max(-1, Math.min(1, v * g)));
    writeWavFloat(path.join(dir, "raw.wav"), [scaled], RATE);
    const args = ["--raw", path.join(dir, "raw.wav"), "--ref", path.join(srcDir, "ref.wav"), "--out", path.join(dir, "sent.wav")];
    if (opt.plain) args.push("--agc", "1");
    else { args.push("--agc", "0", "--warmup", "1", "--gated-gain", "1"); for (const kv of opt.guard || []) args.push("--guard", kv); }
    const stats = JSON.parse(execFileSync(REPLAY, args, { encoding: "utf8" }));
    if (sub.kind !== "native") fs.rmSync(path.join(dir, "raw.wav"));  // browser subjects are analysed from sent.wav only
    fs.writeFileSync(path.join(tmp, "results.json"), JSON.stringify({ ...results, subjects: [{ ...sub, dir }] }, null, 2));
    execFileSync(process.execPath, [path.join(HERE, "bench.mjs"), "--reanalyze", tmp], { stdio: "ignore" });
    const a = JSON.parse(fs.readFileSync(path.join(tmp, "results.json"), "utf8")).subjects[0].analysis || {};
    const r = (v) => (typeof v === "number" ? +v.toFixed(1) : v ?? null);
    return { f: r(a.guestMargin), audible: r(a.guestAudiblePct), dtAudible: r(a.guestDtAudiblePct), send: r(a.sendLevelDb), peak: r(a.peakDb),
      pumping: r(a.pumpingDb), talkOver: r(a.talkOverKeptDb), floor: r(a.floorDb), gainDb: r(stats.gainDb) };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2), opt = { guard: [] }, pos = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--scale") opt.scale = parseFloat(argv[++i]);
    else if (argv[i] === "--guard") opt.guard.push(argv[++i]);
    else if (argv[i] === "--plain") opt.plain = true;
    else pos.push(argv[i]);
  }
  console.log(JSON.stringify(tuneCheck(pos[0], pos[1], pos[2], opt)));
}
