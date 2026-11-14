#!/usr/bin/env node
// Audio Bench: runs subjects (native audio paths, browsers) through one scenario and writes one report.
// See README.md. Usage: tools/audio-bench/run.sh [--subjects webrtc,apple,raw] [--volumes 12,25,40] ...
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { RATE, analyze, boundaries, readWav, scheduled, writeWavFloat } from "./analyze.mjs";
import { renderReport } from "./report.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const HOME = os.homedir();
const DERIVED = path.join(HOME, "Developer/Browsa/derived");
const BENCH = path.join(DERIVED, "audio-bench");
const LAB = path.join(DERIVED, "audio-lab/Browsa Audio Lab.app/Contents/MacOS/audiolab");
const MAX_VOLUME = 60;

// ---------- arguments ----------
const args = { subjects: "webrtc,apple,raw", volumes: "50,60", in: "", out: "", "talker-out": "MacBook Pro Speakers", "talker-volume": "1", schedule: "4,20,15,20,3" };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (!a.startsWith("--")) continue;
  const v = process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[++i] : "1";
  args[a.slice(2)] = v;
}
if (args.help) {
  console.log(fs.readFileSync(path.join(HERE, "README.md"), "utf8"));
  process.exit(0);
}
if (args.long) {
  const half = Math.round((parseFloat(args.long) * 60) / 2);
  args.schedule = `4,${half},10,${half},3`;
}
if (args.reanalyze) args.schedule = JSON.parse(fs.readFileSync(path.join(path.resolve(args.reanalyze), "results.json"), "utf8")).schedule.join(",");
const seconds = args.schedule.split(",").map(Number);
if (seconds.length !== 5 || seconds.some((s) => !(s >= 0))) throw new Error("--schedule needs five numbers");
const total = seconds.reduce((a, b) => a + b, 0);
const volumes = args.volumes && args.volumes !== "same" ? args.volumes.split(",").map(Number) : [null];
for (const v of volumes) if (v != null && (!(v >= 0) || v > MAX_VOLUME)) throw new Error(`volume ${v}: the bench never goes above ${MAX_VOLUME}`);
const talkerVolume = Math.min(Math.max(parseFloat(args["talker-volume"]), 0), 1);

// ---------- one bench at a time ----------
fs.mkdirSync(BENCH, { recursive: true });
const LOCK = path.join(BENCH, ".lock");
try {
  const pid = parseInt(fs.readFileSync(LOCK, "utf8"), 10);
  if (pid && pid !== process.pid) {
    try { process.kill(pid, 0); console.error(`Another bench run is active (pid ${pid}). Not starting.`); process.exit(1); } catch {}
  }
} catch {}
fs.writeFileSync(LOCK, String(process.pid));

// ---------- system volume, always restored ----------
const osa = (s) => execFileSync("osascript", ["-e", s], { encoding: "utf8" }).trim();
const startVolume = parseInt(osa("output volume of (get volume settings)"), 10);
let volumeChanged = false;
const children = new Set();
function cleanup() {
  for (const c of children) try { c.kill("SIGTERM"); } catch {}
  if (volumeChanged) try { osa(`set volume output volume ${startVolume}`); volumeChanged = false; } catch {}
  try { if (fs.readFileSync(LOCK, "utf8") === String(process.pid)) fs.unlinkSync(LOCK); } catch {}
}
process.on("exit", cleanup);
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => { cleanup(); process.exit(130); });
process.on("uncaughtException", (e) => { console.error(e); cleanup(); process.exit(1); });
function setVolume(v) {
  if (v == null) return;
  osa(`set volume output volume ${v}`);
  volumeChanged = true;
}

// ---------- stimuli ----------
const STIM = path.join(BENCH, "stimuli");
fs.mkdirSync(STIM, { recursive: true });
const standardFar = path.join(STIM, "far.wav"), nearWav = path.join(STIM, "near.wav");
if (!fs.existsSync(standardFar)) execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1", path.join(REPO, "tools/echo-test/standup.mp3"), standardFar]);
// The far end: the standup recording (default), "natural" (the same voice cut into phrases with pauses of
// 0.3 to 1.8 s and phrases from 12 dB quieter to 3 dB louder, so word onsets after silence and quiet
// phrases get tested), or any recording, e.g. of your own voice (people are most sensitive to their own).
let farWav = standardFar;
if (args.reanalyze) {
  try { farWav = JSON.parse(fs.readFileSync(path.join(path.resolve(args.reanalyze), "results.json"), "utf8")).farStimulus || standardFar; } catch {}
} else if (args.far === "natural") {
  farWav = path.join(STIM, "far-natural.wav");
  if (!fs.existsSync(farWav)) {
    const src = readWav(standardFar).channels[0], out = [];
    let seed = 7, p = 0, g = 0;
    const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
    const gains = [0, -6, -12, 3, -3, -9];
    while (p < src.length && out.length < 120 * RATE) {
      const len = Math.floor((2 + 2 * rnd()) * RATE), gain = 10 ** (gains[g++ % gains.length] / 20);
      for (let i = 0; i < len && p < src.length; i++, p++) out.push(src[p] * gain * Math.min(1, i / 480, (len - i) / 480));
      const pause = Math.floor((0.3 + 1.5 * rnd()) * RATE);
      for (let i = 0; i < pause; i++) out.push(0);
    }
    let peak = 0;
    for (const v of out) peak = Math.max(peak, Math.abs(v));
    const k = peak > 0.89 ? 0.89 / peak : 1;
    writeWavFloat(farWav, [Float32Array.from(out, (v) => v * k)], RATE);
  }
} else if (args.far) {
  farWav = path.join(STIM, `far-${path.basename(args.far).replace(/\.[^.]+$/, "").replace(/[^A-Za-z0-9_-]/g, "_")}.wav`);
  execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1", path.resolve(args.far), farWav]);
}
if (!fs.existsSync(nearWav)) {
  // A different voice from the far end, standing in for you. About 45 s, so it doesn't loop in a normal run.
  const text = fs.readFileSync(path.join(HERE, "talker.txt"), "utf8");
  const aiff = path.join(STIM, "near.aiff");
  execFileSync("say", ["-v", "Daniel", "-r", "175", "-o", aiff, text]);
  execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1", aiff, nearWav]);
  fs.unlinkSync(aiff);
}
// --prepare-stimuli: make the stimulus files and stop (nothing is played).
if (args["prepare-stimuli"]) { console.log(`far: ${farWav}\nnear: ${nearWav}`); process.exit(0); }
const b = boundaries(seconds);
const stim = { far: scheduled(readWav(farWav).channels[0], b, "far"), near: scheduled(readWav(nearWav).channels[0], b, "near") };

// The same analysis for any subject's folder (sent.wav, and raw.wav / channels.wav when native).
function analyzeDir(dir, kind) {
  const rec = { sent: readWav(path.join(dir, "sent.wav")).channels[0] };
  if (fs.existsSync(path.join(dir, "raw.wav"))) rec.raw = readWav(path.join(dir, "raw.wav")).channels[0];
  if (fs.existsSync(path.join(dir, "channels.wav"))) rec.channels = readWav(path.join(dir, "channels.wav"));
  // Native: the mic can start up to ~1 s after the speakers. Browsers: the page starts its schedule after
  // it starts recording, and the talker is started by the bench when the page says so.
  let opts = { farLagMs: [-1500, 500], nearLagMs: [-1500, 1500] };
  if (kind === "meet") {
    // The guest's own recording: its schedule starts 0.3 s in; the echo comes back a network round trip later.
    opts = { farLagMs: [200, 3000], nearLagMs: [-500, 4000] };
  } else if (kind !== "native") {
    // The page says when its schedule started in its recording; the far end comes back a little after that
    // (output and input latency). Without that, a well-cancelled far end leaves too little to find reliably.
    let start = null;
    try { start = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")).scheduleStartSec; } catch {}
    opts = { farLagMs: start != null ? [start * 1000 - 50, start * 1000 + 400] : [-500, 4000], nearLagMs: [-500, 5000] };
  }
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")); } catch {}
  opts.guest = { oneWayMs: parseFloat(args["one-way-ms"] || "300"), localMs: meta.delayMs > 0 ? meta.delayMs : 50 };
  const a = analyze(rec, stim, seconds, opts);
  a.listen = guestFiles(dir, rec.sent, a);
  return a;
}

// What the far participant would hear: what Browsa sends back during their speech (far end only, then both
// talking), arriving one network round trip after they spoke. Also mixed under their own voice at the true
// relative level, and turned up 30 dB so faint leak is easy to judge. Listen at low volume.
function guestFiles(dir, sent, a) {
  if (!a.guest) return [];
  const F = Math.round((a.farLagMs * RATE) / 1000), rt = Math.round((2 * a.guest.oneWayMs * RATE) / 1000);
  const from = b[1], to = b[4], n = to + rt + RATE;
  const back = new Float32Array(n), withOwn = new Float32Array(n), loud = new Float32Array(n);
  for (let p = from; p < to; p++) {
    const v = sent[p + F] || 0, t = p + rt;
    back[t] = v;
    loud[t] = Math.max(-1, Math.min(1, v * 31.6));
  }
  for (let p = 0; p < n; p++) withOwn[p] = back[p] + (p < stim.far.length ? stim.far[p] : 0);
  const files = [["guest-hears.wav", back, "Guest hears (their echo)"], ["guest-hears-with-own-voice.wav", withOwn, "Under their own voice"], ["guest-hears-plus30dB.wav", loud, "Echo +30 dB"]];
  for (const [name, data] of files) writeWavFloat(path.join(dir, name), [data], RATE);
  return files.map(([name, , label]) => ({ label, href: "file://" + path.join(dir, name) }));
}

function writeReport(dir, result) {
  fs.writeFileSync(path.join(dir, "results.json"), JSON.stringify(result, (k, v) => (k === "strip" ? undefined : v), 2));
  fs.writeFileSync(path.join(dir, "report.html"), renderReport(result));
  const latest = path.join(BENCH, "latest");
  fs.mkdirSync(latest, { recursive: true });
  fs.copyFileSync(path.join(dir, "report.html"), path.join(latest, "report.html"));
  fs.copyFileSync(path.join(dir, "results.json"), path.join(latest, "results.json"));
  console.log(`Report: ${path.join(dir, "report.html")}`);
}

// --reanalyze <run folder>: analysis and report again from the recordings, without playing anything.
if (args.reanalyze) {
  const dir = path.resolve(args.reanalyze), result = JSON.parse(fs.readFileSync(path.join(dir, "results.json"), "utf8"));
  for (const sub of result.subjects) if (sub.status === "ok") { process.stdout.write(`${sub.name}… `); sub.analysis = analyzeDir(sub.dir, sub.kind || "native"); console.log("done"); }
  writeReport(dir, result);
  process.exit(0);
}

// ---------- subjects ----------
const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
const RUN = path.join(BENCH, stamp);
fs.mkdirSync(RUN, { recursive: true });

const NATIVE = {
  webrtc: "Browsa core (WebRTC, native)",
  "webrtc-agc": "Browsa core + auto gain (native)",
  apple: "Apple voice processing (native)",
  raw: "No processing (raw mic)",
};

function run(cmd, argv, timeoutMs) {
  return new Promise((resolve) => {
    const c = spawn(cmd, argv, { stdio: ["ignore", "pipe", "pipe"] });
    children.add(c);
    let out = "", timedOut = false;
    c.stdout.on("data", (d) => (out += d));
    c.stderr.on("data", (d) => (out += d));
    const t = setTimeout(() => { timedOut = true; c.kill("SIGTERM"); }, timeoutMs);
    c.on("close", (code) => { clearTimeout(t); children.delete(c); resolve({ code, out, timedOut }); });
  });
}

async function nativeSubject(mode, volume) {
  const id = volume == null ? mode : `${mode}-v${volume}`, dir = path.join(RUN, id);
  const name = NATIVE[mode] + (volume == null ? "" : ` @ volume ${volume}`);
  const argv = ["--mode", mode === "webrtc-agc" ? "webrtc" : mode, ...(mode === "webrtc-agc" ? ["--gain"] : []), "--far", farWav, "--talker", nearWav, "--talker-out", args["talker-out"], "--talker-volume", String(talkerVolume),
    "--schedule", seconds.join(","), "--out-dir", dir];
  if (args.in) argv.push("--in", args.in);
  if (args.out) argv.push("--out", args.out);
  if (args.channels) argv.push("--channels", args.channels);
  process.stdout.write(`${name}: running ${total} s… `);
  const r = await run(LAB, argv, (total + 40) * 1000);
  if (r.timedOut) { console.log("timed out"); return { id, name, volume, status: "skipped: timed out (needs a click?)", dir }; }
  if (r.code !== 0) {
    const why = /not allowed/.test(r.out) ? "skipped: needs a click (microphone permission)" : `failed: ${r.out.trim().split("\n").pop()}`;
    console.log(why);
    return { id, name, volume, status: why, dir };
  }
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));
  const analysis = analyzeDir(dir, "native");
  console.log(`echo ${analysis.echoAboveQuietDb?.toFixed(1)} dB above quiet, send ${analysis.sendLevelDb?.toFixed(1)} dBFS, talk-over ${analysis.talkOverKeptDb?.toFixed(1)} dB`);
  return { id, name, volume, kind: "native", mode, status: "ok", dir, meta, analysis };
}

// ---------- browsers: a local page that records what the mic track would send ----------
let PORT = parseInt(args.port || "8777", 10);
const pending = new Map();  // subject id -> { dir, meta, resolve, talker }
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`), id = url.searchParams.get("subject");
  const send = (code, body = "", type = "text/plain") => { res.writeHead(code, { "content-type": type, "cache-control": "no-store" }); res.end(body); };
  if (req.method === "GET") {
    if (url.pathname === "/" || url.pathname === "/bench.html") return send(200, fs.readFileSync(path.join(HERE, "page/bench.html")), "text/html");
    if (url.pathname === "/stimuli/far.wav") return send(200, fs.readFileSync(farWav), "audio/wav");
    return send(404);
  }
  const body = [];
  req.on("data", (d) => body.push(d));
  req.on("end", () => {
    const p = pending.get(id), buf = Buffer.concat(body);
    if (!p) return send(404, "no such subject");
    if (url.pathname === "/talker") {
      // The page's schedule starts now: the talker follows the same schedule from here.
      p.talker = run(LAB, ["--mode", "play", "--talker", nearWav, "--talker-out", args["talker-out"], "--talker-volume", String(talkerVolume),
        "--schedule", seconds.join(","), "--out-dir", path.join(p.dir, "talker")], (total + 20) * 1000);
    } else if (url.pathname === "/status") fs.appendFileSync(path.join(p.dir, "page.log"), `${new Date().toISOString()} ${buf.toString("utf8")}\n`);
    else if (url.pathname === "/meta") p.meta = JSON.parse(buf.toString("utf8"));
    else if (url.pathname === "/error") p.resolve({ error: JSON.parse(buf.toString("utf8")) });
    else if (url.pathname === "/result") {
      const pcm = new Float32Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length - (buf.length % 4)));
      p.resolve({ pcm });
    }
    send(200, "ok");
  });
});
// First free port from 8777 (other local servers may hold the usual ones).
for (let tries = 0; ; tries++, PORT++) {
  const ok = await new Promise((r) => { server.once("error", () => r(false)); server.listen(PORT, "127.0.0.1", () => r(true)); });
  if (ok) break;
  if (tries > 20) throw new Error("no free port for the bench page");
}

const SPIKE = path.join(DERIVED, "webkit-spike/run.sh");
const BROWSERS = {
  chrome: { name: "Chrome (WebRTC processing)", start: chromeStart },
  spike: { name: "Browsa WebKit Spike, patched (WebRTC in WebKit)", start: (url, dir) => spikeStart(url, dir, false) },
  "spike-apple": { name: "Browsa WebKit Spike, Apple processing", start: (url, dir) => spikeStart(url, dir, true) },
  safari: { name: "Safari (manual, one click)", manual: true, start: (url) => run("open", ["-a", "Safari", url + "&manual=1"], 15000) },
};
function chromeStart(url, dir) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "audio-bench-chrome-"));
  const c = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [`--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--use-fake-ui-for-media-stream", "--autoplay-policy=no-user-gesture-required", "--disable-background-timer-throttling", "--new-window", url], { stdio: "ignore" });
  children.add(c);
  return { stop: () => new Promise((r) => { c.once("close", () => { children.delete(c); fs.rmSync(profile, { recursive: true, force: true }); r(); }); c.kill("SIGTERM"); setTimeout(() => c.kill("SIGKILL"), 4000); }) };
}

// Browsa WebKit Spike on the patched WebKit (Spike/CallAudio/webkit/build-browsa.sh), opened on the bench page
// by its test-only AudioBench hook. Its stderr goes to app.log. (WebKit's own logs need admin to read.)
function spikeStart(url, dir, apple) {
  if (!fs.existsSync(SPIKE)) throw new Error(`no ${SPIKE}: run Spike/CallAudio/webkit/build-browsa.sh`);
  const out = fs.openSync(path.join(dir, "app.log"), "w");
  const app = spawn(SPIKE, apple ? ["apple"] : [], { stdio: ["ignore", out, out], env: { ...process.env, BROWSA_AUDIO_BENCH: "1", BROWSA_AUDIO_BENCH_URL: url, ...(apple ? {} : { BROWSA_CALL_AUDIO_DUMP: path.join(dir, "unit-dump") }) } });
  if (!apple) fs.mkdirSync(path.join(dir, "unit-dump"), { recursive: true });
  children.add(app);
  return { stop: () => new Promise((r) => { if (app.exitCode != null) return r(); app.once("close", () => { children.delete(app); r(); }); app.kill("SIGTERM"); setTimeout(() => app.kill("SIGKILL"), 5000); }) };
}

async function browserSubject(key, volume, extra = {}) {
  const def = { ...BROWSERS[key], ...extra };
  const id = volume == null ? key : `${key}-v${volume}`, dir = path.join(RUN, id), name = def.name + (volume == null ? "" : ` @ volume ${volume}`);
  fs.mkdirSync(dir, { recursive: true });
  if (def.manual && !args.manual) return { id, name, volume, status: "skipped: needs a click (run with --manual)", dir };
  const url = `http://127.0.0.1:${PORT}/bench.html?subject=${encodeURIComponent(id)}&schedule=${seconds.join(",")}`;
  process.stdout.write(`${name}: running ${total} s… `);
  const done = new Promise((resolve) => pending.set(id, { dir, resolve }));
  const app = await def.start(url, dir);
  const timeoutMs = (total + (def.manual ? 180 : 45)) * 1000;
  const r = await Promise.race([done, new Promise((res) => setTimeout(() => res({ timeout: true }), timeoutMs))]);
  const p = pending.get(id);
  pending.delete(id);
  if (app?.stop) await app.stop();
  if (p?.talker) await p.talker;
  if (r.timeout) { console.log("timed out"); return { id, name, volume, status: "skipped: timed out (needs a click?)", dir }; }
  if (r.error) { console.log(`failed: ${r.error.name}`); return { id, name, volume, status: `skipped: ${r.error.name}: ${r.error.message}`, dir }; }
  writeWavFloat(path.join(dir, "sent.wav"), [r.pcm], RATE);
  const meta = { ...(p.meta || {}), output: args.out || "default output", talkerOutput: args["talker-out"] };
  fs.writeFileSync(path.join(dir, "meta.json"), JSON.stringify(meta, null, 2));
  const analysis = analyzeDir(dir, "browser");
  console.log(`echo ${analysis.echoAboveQuietDb?.toFixed(1)} dB above quiet, send ${analysis.sendLevelDb?.toFixed(1)} dBFS, talk-over ${analysis.talkOverKeptDb?.toFixed(1)} dB`);
  return { id, name, volume, kind: "browser", status: "ok", dir, meta, analysis };
}

// The robot guest (guest.mjs) on a real Meet that the build under test is already in. It waits to be admitted;
// once in, it talks (far end) on the schedule and the bench starts the stand-in talker in the room.
async function meetSubject(volume) {
  const id = volume == null ? "meet" : `meet-v${volume}`, dir = path.join(RUN, id);
  const name = `Real Meet call, robot guest (${args.host || "host build not stated"})` + (volume == null ? "" : ` @ volume ${volume}`);
  if (!args["meet-url"]) return { id, name, volume, status: "skipped: no --meet-url", dir };
  fs.mkdirSync(dir, { recursive: true });
  console.log(`${name}: asking to join ${args["meet-url"]}; admit "Echo guest" in the host browser.`);
  const c = spawn(process.execPath, [path.join(HERE, "guest.mjs"), "--url", args["meet-url"], "--far", farWav, "--schedule", seconds.join(","), "--out-dir", dir,
    "--wait-min", args["wait-min"] || "10"], { stdio: ["ignore", "pipe", "inherit"] });
  children.add(c);
  let talker = null;
  c.stdout.on("data", (d) => {
    if (/GUEST_STARTED/.test(String(d)) && !talker)
      talker = run(LAB, ["--mode", "play", "--talker", nearWav, "--talker-out", args["talker-out"], "--talker-volume", String(talkerVolume),
        "--schedule", seconds.join(","), "--out-dir", path.join(dir, "talker")], (total + 20) * 1000);
  });
  const code = await new Promise((r) => c.on("close", r));
  children.delete(c);
  if (talker) await talker;
  if (code !== 0 || !fs.existsSync(path.join(dir, "sent.wav"))) return { id, name, volume, status: talker ? "failed during the call" : "skipped: not admitted (or Meet turned the guest away)", dir };
  const analysis = analyzeDir(dir, "meet");
  console.log(`  guest hears own echo in ${analysis.guestAudiblePct}% of their speech, G.131 f ${analysis.guestMargin?.toFixed(1)}`);
  return { id, name, volume, kind: "meet", status: "ok", dir, meta: JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")), analysis };
}

const subjects = [];
const wanted = args.subjects.split(",").map((s) => s.trim()).filter(Boolean);
const devices = JSON.parse(execFileSync(LAB, ["--list-devices"], { encoding: "utf8" }));
for (const volume of volumes) {
  setVolume(volume);
  for (const s of wanted) {
    if (NATIVE[s]) subjects.push(await nativeSubject(s, volume));
    else if (BROWSERS[s]) subjects.push(await browserSubject(s, volume));
    else if (s === "meet") subjects.push(await meetSubject(volume));
    else subjects.push({ id: s, name: s, volume, status: "skipped: not supported yet" });
    await new Promise((r) => setTimeout(r, 1000));
  }
}
if (volumeChanged) { osa(`set volume output volume ${startVolume}`); volumeChanged = false; }
server.close();

// ---------- report ----------
const description = `Schedule ${seconds.join(" / ")} s (quiet, far end, you, both, quiet). Far end: ${path.basename(farWav) === "far.wav" ? "standup recording" : path.basename(farWav)} on ${args.out || "the default output"}; you: "Daniel" voice on ${args["talker-out"]} at ${Math.round(talkerVolume * 100)}%. System volume started at ${startVolume}${volumes[0] != null ? `, swept ${volumes.join(", ")}` : ""} and was restored.`;
const result = { startedAt: stamp, description, farStimulus: farWav, schedule: seconds, startVolume, volumes, devices, subjects };
writeReport(RUN, result);
process.exit(0);
