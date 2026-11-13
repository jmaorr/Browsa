// Meet echo bot: an echo test over a real Google Meet call.
//
// A Chromium guest joins a Meet link you give it, "talks" by playing standup.wav as its microphone,
// and records what the other side (Browsa) sends back. Anything of its own voice in that is echo.
// Its own speaker output is muted, so the only sound in the room is Browsa playing the bot.
//
//   node bot.mjs --url https://meet.google.com/abc-defg-hij [--seconds 60] [--name "Echo bot"] [--show]
//   node bot.mjs --selftest        (no Meet, no sound: checks recording and scoring on a local loopback)
//
// Stay quiet while it runs: your own voice would count as echo.
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname);
const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i < 0 ? d : (process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : true); };
const URL_ = arg('url'), SECONDS = Number(arg('seconds', 60)), NAME = arg('name', 'Echo bot');
const SELFTEST = !!arg('selftest'), SHOW = !!arg('show');
const RATE = 48000;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

if (!SELFTEST && !(typeof URL_ === 'string' && /^https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}/.test(URL_))) {
  console.error('Give it your Meet link: node bot.mjs --url https://meet.google.com/abc-defg-hij'); process.exit(2);
}

// The bot's voice: the stand-up recording as 48 kHz mono WAV (Chromium's fake mic loops it).
const WAV = path.join(HERE, 'standup.wav');
if (!fs.existsSync(WAV)) {
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', path.join(HERE, '..', 'standup.mp3'), '-ar', String(RATE), '-ac', '1', '-sample_fmt', 's16', WAV]);
}

// ---------- in the page: find the call's audio and record it ----------
// Channel 0: what the bot sends (its mic after Chromium's processing). Channel 1: everything it receives.
const INIT = () => {
  const B = window.__echoBot = { remote: [], local: null, rec: null };
  const NativePC = window.RTCPeerConnection;
  const PC = function RTCPeerConnection(...a) {
    const pc = new NativePC(...a);
    pc.addEventListener('track', e => { if (e.track.kind === 'audio') { B.remote.push(e.track); if (B.rec) B.rec.addRemote(e.track); } });
    return pc;
  };
  PC.prototype = NativePC.prototype; Object.setPrototypeOf(PC, NativePC);
  window.RTCPeerConnection = PC;
  const md = navigator.mediaDevices, gum = md.getUserMedia.bind(md);
  md.getUserMedia = async c => { const s = await gum(c); const t = s.getAudioTracks()[0]; if (t) B.local = t; return s; };
  B.start = () => {
    const ctx = new AudioContext({ sampleRate: 48000 });
    const merger = ctx.createChannelMerger(2), remoteBus = ctx.createGain();
    remoteBus.connect(merger, 0, 1);
    if (B.local) ctx.createMediaStreamSource(new MediaStream([B.local])).connect(merger, 0, 0);
    const added = new Set();
    B.rec = { addRemote: t => {
      if (added.has(t.id) || t.readyState === 'ended') return;
      added.add(t.id);
      const ms = new MediaStream([t]);
      // Chromium only decodes a remote WebRTC track once a media element plays it; a muted one is enough.
      const el = new Audio(); el.muted = true; el.srcObject = ms; el.play().catch(() => {});
      ctx.createMediaStreamSource(ms).connect(remoteBus);
    } };
    B.remote.forEach(B.rec.addRemote);
    const sp = ctx.createScriptProcessor(4096, 2, 1);
    B.chunks = [[], []];
    sp.onaudioprocess = e => { for (const c of [0, 1]) B.chunks[c].push(new Float32Array(e.inputBuffer.getChannelData(c))); };
    merger.connect(sp);
    const mute = ctx.createGain(); mute.gain.value = 0; sp.connect(mute); mute.connect(ctx.destination);
    B.ctx = ctx;
    return { remoteTracks: added.size, local: !!B.local, rate: ctx.sampleRate };
  };
  B.status = () => ({ remoteTracks: B.remote.filter(t => t.readyState === 'live').length, local: !!B.local, recorded: B.chunks ? B.chunks[0].length * 4096 / 48000 : 0 });
  B.stop = () => {
    B.ctx.close();
    const cat = a => { const n = a.reduce((s, b) => s + b.length, 0), o = new Float32Array(n); let k = 0; for (const b of a) { o.set(b, k); k += b.length; } return o; };
    B.out = [cat(B.chunks[0]), cat(B.chunks[1])];
    return B.out[0].length;
  };
  B.slice = (ch, from, n) => {
    const a = B.out[ch].subarray(from, from + n), i16 = new Int16Array(a.length);
    for (let i = 0; i < a.length; i++) i16[i] = Math.max(-32768, Math.min(32767, Math.round(a[i] * 32767)));
    const u = new Uint8Array(i16.buffer); let s = '';
    for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
    return btoa(s);
  };
};

async function fetchRecording(page) {
  const n = await page.evaluate(() => window.__echoBot.stop());
  const out = [new Float32Array(n), new Float32Array(n)], STEP = RATE * 5;
  for (const ch of [0, 1]) for (let o = 0; o < n; o += STEP) {
    const i16 = new Int16Array(Buffer.from(await page.evaluate(([c, f, k]) => window.__echoBot.slice(c, f, k), [ch, o, STEP]), 'base64').buffer.slice(0));
    for (let i = 0; i < i16.length; i++) out[ch][o + i] = i16[i] / 32767;
  }
  return out;
}

// ---------- scoring, the same idea as the echo test page ----------
// Levels in 20 ms blocks. "During" is where the bot was talking (shifted by the round trip), "floor"
// the median level well away from it. The round trip comes from correlating the two envelopes.
function score(sent, got) {
  const B = RATE / 50;
  const lv = a => { const r = []; for (let o = 0; o + B <= a.length; o += B) { let p = 0; for (let i = o; i < o + B; i++) p += a[i] * a[i]; r.push(10 * Math.log10(p / B + 1e-15)); } return r; };
  const S = lv(sent), G = lv(got);
  // Round trip: 5 ms amplitude envelopes, normalised cross-correlation over 0..2 s.
  const E = RATE / 200;
  const env = a => { const r = new Float64Array(Math.floor(a.length / E)); for (let k = 0; k < r.length; k++) { let p = 0; for (let i = k * E; i < (k + 1) * E; i++) p += a[i] * a[i]; r[k] = Math.sqrt(p / E); } return r; };
  const es = env(sent), eg = env(got);
  const norm = r => { const m = r.reduce((s, v) => s + v, 0) / r.length; return r.map(v => v - m); };
  const ns = norm(es), ng = norm(eg);
  let best = { lag: 0, c: -1 };
  for (let lag = 0; lag <= 400; lag++) {
    let c = 0, a = 0, b = 0;
    for (let k = 0; k + lag < ng.length && k < ns.length; k++) { c += ns[k] * ng[k + lag]; a += ns[k] * ns[k]; b += ng[k + lag] * ng[k + lag]; }
    c /= Math.sqrt(a * b) + 1e-12;
    if (c > best.c) best = { lag, c };
  }
  // Weak correlation means little or no echo to line up on; assume a typical round trip then.
  const lagMs = best.c > 0.15 ? best.lag * 5 : 300;
  const lagBlocks = Math.round(lagMs / 20);
  const top = Math.max(...S), talking = S.map(v => v > top - 30);
  const at = i => i >= 0 && i < talking.length && talking[i];
  const during = [], quiet = [];
  G.forEach((v, i) => {
    const j = i - lagBlocks;
    let near = false; for (let k = j - 15; k <= j + 8; k++) if (at(k)) { near = true; break; }
    if (!near) quiet.push(v);
    else if (at(j) || at(j - 1) || at(j - 2)) during.push(v);
  });
  const med = a => { const s = [...a].sort((p, q) => p - q); return s[Math.floor(s.length / 2)]; };
  const pm = a => 10 * Math.log10(a.reduce((s, d) => s + 10 ** (d / 10), 0) / a.length);
  const floor = med(quiet), dur = pm(during);
  return {
    floorDb: +floor.toFixed(1), duringDb: +dur.toFixed(1), aboveDb: +(dur - floor).toFixed(1),
    roundTripMs: lagMs, correlation: +best.c.toFixed(2), sentDb: +pm(S.filter((_, i) => talking[i])).toFixed(1),
    talkingSeconds: +(talking.filter(Boolean).length / 50).toFixed(1), quietSeconds: +(quiet.length / 50).toFixed(1),
  };
}

function writeWav(file, chans) {
  const n = chans[0].length, c = chans.length, buf = Buffer.alloc(44 + n * c * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * c * 2, 4); buf.write('WAVEfmt ', 8); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); buf.writeUInt16LE(c, 22); buf.writeUInt32LE(RATE, 24); buf.writeUInt32LE(RATE * c * 2, 28);
  buf.writeUInt16LE(c * 2, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * c * 2, 40);
  for (let i = 0; i < n; i++) for (let k = 0; k < c; k++) buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(chans[k][i] * 32767))), 44 + (i * c + k) * 2);
  fs.writeFileSync(file, buf);
}

// ---------- run ----------
// Playwright's own Chromium when it's installed, else the Google Chrome app (a separate, throwaway profile).
const browser = await chromium.launch({
  ...(fs.existsSync(chromium.executablePath()) ? {} : { channel: 'chrome' }),
  headless: SELFTEST && !SHOW,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${WAV}`,
    '--mute-audio',                                   // the bot never plays anything through this Mac's speakers
    '--autoplay-policy=no-user-gesture-required',
    ...(SHOW ? [] : ['--window-position=-2400,-2400', '--window-size=1100,800']),
  ],
});
const context = await browser.newContext({ permissions: ['microphone', 'camera'], viewport: { width: 1100, height: 800 } });
await context.addInitScript(INIT);
const page = await context.newPage();

// Browsa's call log, alongside.
const logFile = path.join(os.homedir(), 'Library/Logs/Browsa/call-audio.log');
const tail = SELFTEST ? null : spawn('tail', ['-n0', '-F', logFile], { stdio: ['ignore', 'pipe', 'ignore'] });
tail?.stdout.on('data', d => String(d).trim().split('\n').forEach(l => log('[browsa]', l.slice(0, 220))));

let result;
try {
  if (SELFTEST) {
    // A loopback call on a local page: what the bot receives is its own voice, so the score should be
    // high (all "echo") with a short round trip. Checks capture, transfer and scoring without Meet or sound.
    await page.route('https://selftest.local/', r => r.fulfill({ contentType: 'text/html', body: '<title>selftest</title>' }));
    await page.goto('https://selftest.local/');
    await page.evaluate(async () => {
      const s = await navigator.mediaDevices.getUserMedia({ audio: true });
      const a = new RTCPeerConnection(), b = new RTCPeerConnection();
      a.onicecandidate = e => e.candidate && b.addIceCandidate(e.candidate);
      b.onicecandidate = e => e.candidate && a.addIceCandidate(e.candidate);
      a.addTrack(s.getAudioTracks()[0], s);
      await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
      await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
      window.__pcs = [a, b];
    });
    await page.waitForTimeout(1000);
  } else {
    log('Opening', URL_);
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    const click = async (re, ms = 2000) => { const b = page.getByRole('button', { name: re }).first(); if (await b.isVisible({ timeout: ms }).catch(() => false)) { await b.click(); return true; } return false; };
    await click(/got it|dismiss/i, 4000);
    const nameBox = page.getByRole('textbox', { name: /name/i }).first();
    if (await nameBox.isVisible({ timeout: 15000 }).catch(() => false)) await nameBox.fill(NAME);
    await click(/turn off camera/i, 5000);
    if (!(await click(/ask to join|join now|join anyway/i, 15000))) {
      const text = (await page.locator('body').innerText().catch(() => '')).slice(0, 300).replace(/\s+/g, ' ');
      throw new Error('No join button. The page says: ' + text);
    }
    log(`Asked to join as "${NAME}". Admit it in Browsa (waiting up to 5 minutes).`);
    await page.getByRole('button', { name: /leave call/i }).first().waitFor({ timeout: 5 * 60000 });
    log('In the call. Stay quiet: the bot is talking now.');
    await page.waitForTimeout(3000);
  }
  const started = await page.evaluate(() => window.__echoBot.start());
  log('Recording', SECONDS, 's', JSON.stringify(started));
  if (!started.local) throw new Error('The bot has no microphone track.');
  for (let t = 0; t < SECONDS; t += 10) {
    await page.waitForTimeout(Math.min(10, SECONDS - t) * 1000);
    log('…', JSON.stringify(await page.evaluate(() => window.__echoBot.status())));
  }
  const [sent, got] = await fetchRecording(page);
  result = score(sent, got);
  const dir = path.join(HERE, 'runs'); fs.mkdirSync(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  writeWav(path.join(dir, `${stamp}.wav`), [sent, got]);
  fs.writeFileSync(path.join(dir, `${stamp}.json`), JSON.stringify({ url: SELFTEST ? 'selftest' : URL_, seconds: SECONDS, ...result }, null, 2));
  const verdict = result.aboveDb <= 3 ? 'No echo got through' : result.aboveDb <= 10 ? 'Faint echo got through' : 'Echo got through';
  log(`${verdict}: floor ${result.floorDb} dBFS, during the bot's speech ${result.duringDb} dBFS, so ${result.aboveDb} dB above the floor` +
      ` (round trip ${result.roundTripMs} ms, correlation ${result.correlation}). Recording: runs/${stamp}.wav (left: sent, right: received)`);
  if (result.quietSeconds < 3) log(`Only ${result.quietSeconds} s of quiet to measure the floor from, so the floor is rough. Run longer (--seconds).`);
  if (!SELFTEST) await page.getByRole('button', { name: /leave call/i }).first().click().catch(() => {});
} catch (e) {
  log('Stopped:', e.message);
  process.exitCode = 1;
} finally {
  tail?.kill();
  await browser.close();
}
