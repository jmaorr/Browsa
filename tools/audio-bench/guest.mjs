#!/usr/bin/env node
// Robot guest for Audio Bench: joins a real Google Meet as a guest, talks with the far-end recording on the
// bench schedule (its "mic" is generated in the page, not a device), and records what it receives: exactly
// what another participant would hear, so the bench can score it with the guest's-ear analysis.
//
//   node guest.mjs --url https://meet.google.com/abc-defg-hij --far far.wav --schedule 4,20,15,20,3 --out-dir DIR
//   node guest.mjs --selftest --far far.wav --near near.wav --out-dir DIR    (silent: no Meet, no devices)
//
// It asks to join and waits (up to --wait-min, default 10) for the host to admit it. Once in, it prints
// "GUEST_STARTED <epoch ms>" (the bench starts the stand-in talker then), plays the schedule, records, leaves.
// Its own speaker output is muted (--mute-audio): the only sound in the room is the call the host hears.
// The guest's voice must come from this recording. Nobody should speak in the room as "the guest": a voice
// the host's mic picks up directly is not echo.
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2), arg = (k, d) => { const i = argv.indexOf("--" + k); return i < 0 ? d : argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : true; };
const URL_ = arg("url"), SELFTEST = !!arg("selftest"), SHOW = !!arg("show"), NAME = arg("name", "Echo guest");
const FAR = arg("far"), NEAR = arg("near"), OUT = arg("out-dir"), WAIT_MIN = Number(arg("wait-min", 10));
const SCHEDULE = String(arg("schedule", "4,20,15,20,3")).split(",").map(Number), TOTAL = SCHEDULE.reduce((a, b) => a + b, 0);
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);
if (!FAR || !OUT || (!SELFTEST && !(typeof URL_ === "string" && /^https:\/\/meet\.google\.com\//.test(URL_)))) {
  console.error("usage: guest.mjs (--url <meet link> | --selftest) --far <wav> --out-dir <dir> [--schedule q,f,n,d,q] [--near <wav> (selftest)]");
  process.exit(2);
}
fs.mkdirSync(OUT, { recursive: true });

// ---------- in the page ----------
// getUserMedia's audio becomes a track the page generates from the far-end recording, silent until start().
// Every remote audio track is recorded (mixed), from start() on.
const INIT = ({ schedule }) => {
  const G = (window.__guest = { remote: [], chunks: [], started: 0 });
  const NativePC = window.RTCPeerConnection;
  const PC = function RTCPeerConnection(...a) {
    const pc = new NativePC(...a);
    pc.addEventListener("track", (e) => { if (e.track.kind === "audio") { G.remote.push(e.track); G.attach?.(e.track); } });
    return pc;
  };
  PC.prototype = NativePC.prototype;
  Object.setPrototypeOf(PC, NativePC);
  window.RTCPeerConnection = PC;
  const ensureCtx = () => {
    if (G.ctx) return G.ctx;
    G.ctx = new AudioContext({ sampleRate: 48000 });
    G.dest = G.ctx.createMediaStreamDestination();
    return G.ctx;
  };
  const md = navigator.mediaDevices, gum = md.getUserMedia.bind(md);
  md.getUserMedia = async (c = {}) => {
    const out = new MediaStream();
    if (c.video) (await gum({ video: c.video })).getVideoTracks().forEach((t) => out.addTrack(t));
    if (c.audio) { ensureCtx(); out.addTrack(G.dest.stream.getAudioTracks()[0].clone()); }
    return out;
  };
  G.start = async () => {
    const ctx = ensureCtx();
    await ctx.resume();
    const buf = await (await fetch("https://bench.local/far.wav")).arrayBuffer().then((b) => ctx.decodeAudioData(b));
    // Record the remote side.
    const bus = ctx.createGain(), sp = ctx.createScriptProcessor(4096, 1, 1), mute = ctx.createGain();
    mute.gain.value = 0; bus.connect(sp); sp.connect(mute); mute.connect(ctx.destination);
    sp.onaudioprocess = (e) => { if (G.recording) G.chunks.push(new Float32Array(e.inputBuffer.getChannelData(0))); };
    const added = new Set();
    G.attach = (t) => {
      if (added.has(t.id) || t.readyState === "ended") return;
      added.add(t.id);
      const ms = new MediaStream([t]);
      const el = new Audio(); el.muted = true; el.srcObject = ms; el.play().catch(() => {});  // Chromium decodes remote audio only once something plays it
      ctx.createMediaStreamSource(ms).connect(bus);
    };
    G.remote.forEach(G.attach);
    // Talk on the schedule: quiet, far end, (near end: the guest is quiet), both, quiet.
    const t0 = ctx.currentTime + 0.3, at = (i) => t0 + schedule.slice(0, i).reduce((a, b) => a + b, 0);
    const play = (start, offset, dur) => {
      if (dur <= 0) return;
      const s = ctx.createBufferSource(), g = ctx.createGain();
      s.buffer = buf; s.loop = true;
      g.gain.setValueAtTime(0, start); g.gain.linearRampToValueAtTime(1, start + 0.05);
      g.gain.setValueAtTime(1, start + dur - 0.05); g.gain.linearRampToValueAtTime(0, start + dur);
      s.connect(g).connect(G.dest); s.start(start, offset % buf.duration); s.stop(start + dur);
    };
    play(at(1), 0, schedule[1]);
    play(at(3), schedule[1], schedule[3]);
    G.recording = true;
    G.started = Date.now();
    return { remoteTracks: added.size, scheduleStartSec: 0.3 };
  };
  G.stop = () => {
    G.recording = false;
    const n = G.chunks.reduce((s, c) => s + c.length, 0), o = new Float32Array(n);
    let k = 0;
    for (const c of G.chunks) { o.set(c, k); k += c.length; }
    G.out = o;
    return n;
  };
  G.slice = (from, n) => {
    const a = G.out.subarray(from, from + n), u = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
    let s = "";
    for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
    return btoa(s);
  };
};

// Selftest host: a second page that receives the guest's voice and sends back a known echo (40 dB down,
// 120 ms late) plus a stand-in talker 6 dB down and a little noise. Checks the whole chain silently.
const HOST = `<!doctype html><title>host</title><script>
window.runHost = async (offer) => {
  const ctx = new AudioContext({ sampleRate: 48000 });
  const near = await (await fetch("https://bench.local/near.wav")).arrayBuffer().then((b) => ctx.decodeAudioData(b));
  const pc = new RTCPeerConnection(), dest = ctx.createMediaStreamDestination();
  pc.ontrack = (e) => {
    const ms = new MediaStream([e.track]), el = new Audio(); el.muted = true; el.srcObject = ms; el.play().catch(() => {});
    const src = ctx.createMediaStreamSource(ms), d = ctx.createDelay(1), g = ctx.createGain();
    d.delayTime.value = 0.12; g.gain.value = 0.01;  // -40 dB
    src.connect(d).connect(g).connect(dest);
  };
  pc.addTrack(dest.stream.getAudioTracks()[0], dest.stream);
  window.hostStartNear = (schedule) => {
    const t0 = ctx.currentTime + 0.3, at = (i) => t0 + schedule.slice(0, i).reduce((a, b) => a + b, 0);
    const s = ctx.createBufferSource(), g = ctx.createGain(); s.buffer = near; g.gain.value = 0.5;
    s.connect(g).connect(dest); s.start(at(2)); s.stop(at(4));
    const n = ctx.createBufferSource(), nb = ctx.createBuffer(1, 48000 * 2, 48000), nd = nb.getChannelData(0);
    for (let i = 0; i < nd.length; i++) nd[i] = (Math.random() * 2 - 1) * 0.0005;
    n.buffer = nb; n.loop = true; n.connect(dest); n.start();
  };
  await pc.setRemoteDescription(offer);
  await pc.setLocalDescription();
  await new Promise((r) => { if (pc.iceGatheringState === "complete") r(); else pc.onicegatheringstatechange = () => pc.iceGatheringState === "complete" && r(); });
  return pc.localDescription.toJSON();
};
</script>`;

const browser = await chromium.launch({
  ...(fs.existsSync(chromium.executablePath()) ? {} : { channel: "chrome" }),
  headless: SELFTEST && !SHOW,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--mute-audio", "--autoplay-policy=no-user-gesture-required",
    ...(SHOW || SELFTEST ? [] : ["--window-position=-2400,-2400", "--window-size=1100,800"])],
});
let exitCode = 0;
try {
  const context = await browser.newContext({ permissions: ["microphone", "camera"], viewport: { width: 1100, height: 800 } });
  await context.route("https://bench.local/far.wav", (r) => r.fulfill({ body: fs.readFileSync(FAR), contentType: "audio/wav", headers: { "access-control-allow-origin": "*" } }));
  if (NEAR) await context.route("https://bench.local/near.wav", (r) => r.fulfill({ body: fs.readFileSync(NEAR), contentType: "audio/wav", headers: { "access-control-allow-origin": "*" } }));
  await context.addInitScript(INIT, { schedule: SCHEDULE });
  const page = await context.newPage();
  let host = null;

  if (SELFTEST) {
    await context.route("https://selftest.local/**", (r) => r.fulfill({ contentType: "text/html", body: r.request().url().endsWith("/host") ? HOST : "<title>guest</title>" }));
    host = await context.newPage();
    await host.goto("https://selftest.local/host");
    await page.goto("https://selftest.local/guest");
    const offer = await page.evaluate(async () => {
      const s = await navigator.mediaDevices.getUserMedia({ audio: true });
      const pc = (window.__pc = new RTCPeerConnection());
      pc.addTrack(s.getAudioTracks()[0], s);
      pc.addTransceiver("audio", { direction: "recvonly" });
      await pc.setLocalDescription();
      await new Promise((r) => { if (pc.iceGatheringState === "complete") r(); else pc.onicegatheringstatechange = () => pc.iceGatheringState === "complete" && r(); });
      return pc.localDescription.toJSON();
    });
    const answer = await host.evaluate((o) => window.runHost(o), offer);
    await page.evaluate((a) => window.__pc.setRemoteDescription(a), answer);
    await page.waitForTimeout(1500);
  } else {
    log("Opening", URL_);
    await page.goto(URL_, { waitUntil: "domcontentloaded" });
    const click = async (re, ms = 2000) => {
      const b = page.getByRole("button", { name: re }).first();
      if (!(await b.waitFor({ state: "visible", timeout: ms }).then(() => true, () => false))) return false;
      await b.click();
      return true;
    };
    await click(/got it|dismiss/i, 4000);
    const nameBox = page.getByRole("textbox", { name: /name/i }).first();
    if (await nameBox.waitFor({ state: "visible", timeout: 30000 }).then(() => true, () => false)) await nameBox.fill(NAME);
    await click(/turn off camera/i, 5000);
    if (!(await click(/ask to join|join now|join anyway/i, 30000))) {
      const text = (await page.locator("body").innerText().catch(() => "")).slice(0, 300).replace(/\s+/g, " ");
      throw new Error("No join button. The page says: " + text);
    }
    log(`Asked to join as "${NAME}". Admit it in the host browser (waiting up to ${WAIT_MIN} minutes).`);
    await page.getByRole("button", { name: /leave call/i }).first().waitFor({ timeout: WAIT_MIN * 60000 });
    log("Admitted. Waiting 3 s for the call to settle.");
    await page.waitForTimeout(3000);
  }

  const started = await page.evaluate(() => window.__guest.start());
  console.log(`GUEST_STARTED ${Date.now()}`);
  if (host) await host.evaluate((s) => window.hostStartNear(s), SCHEDULE);
  log("Talking and recording", TOTAL, "s", JSON.stringify(started));
  if (!started.remoteTracks) log("No remote audio track yet; recording whatever arrives.");
  await page.waitForTimeout((TOTAL + 1.5) * 1000);
  const n = await page.evaluate(() => window.__guest.stop());
  const pcm = new Float32Array(n), STEP = 48000 * 5;
  for (let o = 0; o < n; o += STEP) {
    const b = Buffer.from(await page.evaluate(([f, k]) => window.__guest.slice(f, k), [o, STEP]), "base64");
    pcm.set(new Float32Array(b.buffer, b.byteOffset, b.length / 4), o);
  }
  const { writeWavFloat } = await import("./analyze.mjs");
  writeWavFloat(path.join(OUT, "sent.wav"), [pcm], 48000);
  fs.writeFileSync(path.join(OUT, "meta.json"), JSON.stringify({ guest: true, selftest: SELFTEST, url: SELFTEST ? null : URL_, name: NAME, scheduleStartSec: started.scheduleStartSec,
    recordedSeconds: n / 48000, remoteTracks: started.remoteTracks, output: "the host's call (Meet)", label: "robot guest" }, null, 2));
  log(`Recorded ${(n / 48000).toFixed(1)} s to ${path.join(OUT, "sent.wav")}`);
  if (!SELFTEST) await page.getByRole("button", { name: /leave call/i }).first().click().catch(() => {});
} catch (e) {
  log("Stopped:", e.message);
  exitCode = 1;
} finally {
  await browser.close();
}
process.exit(exitCode);
