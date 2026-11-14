// Audio Bench analysis: the same measurements for every subject, from the recording of what would be
// sent to the other side plus the known stimuli (far end and near-end talker, on the bench schedule).
// Plain Node, no dependencies.
import fs from "node:fs";

export const RATE = 48000;

// ---------- WAV ----------
export function readWav(path) {
  const b = fs.readFileSync(path);
  if (b.toString("ascii", 0, 4) !== "RIFF" || b.toString("ascii", 8, 12) !== "WAVE") throw new Error(`${path}: not a WAV`);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4), len = b.readUInt32LE(off + 4);
    if (id === "fmt ") fmt = { tag: b.readUInt16LE(off + 8), channels: b.readUInt16LE(off + 10), rate: b.readUInt32LE(off + 12), bits: b.readUInt16LE(off + 22) };
    if (id === "data") { data = [off + 8, Math.min(len, b.length - off - 8)]; break; }
    off += 8 + len + (len & 1);
  }
  if (!fmt || !data) throw new Error(`${path}: no fmt/data`);
  let tag = fmt.tag;
  if (tag === 0xfffe) tag = fmt.bits === 32 ? 3 : 1;  // WAVE_FORMAT_EXTENSIBLE: assume the obvious subtype
  const bytes = fmt.bits / 8, frames = Math.floor(data[1] / (bytes * fmt.channels));
  const ch = Array.from({ length: fmt.channels }, () => new Float32Array(frames));
  for (let i = 0, p = data[0]; i < frames; i++)
    for (let c = 0; c < fmt.channels; c++, p += bytes)
      ch[c][i] = tag === 3 ? b.readFloatLE(p) : bytes === 2 ? b.readInt16LE(p) / 32768 : bytes === 3 ? (b.readIntLE(p, 3) / 8388608) : b.readInt32LE(p) / 2147483648;
  return { rate: fmt.rate, channels: ch };
}

export function writeWavFloat(path, channels, rate) {
  const n = channels[0].length, nch = channels.length;
  const b = Buffer.alloc(44 + n * nch * 4);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * nch * 4, 4); b.write("WAVEfmt ", 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(3, 20); b.writeUInt16LE(nch, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * nch * 4, 28);
  b.writeUInt16LE(nch * 4, 32); b.writeUInt16LE(32, 34); b.write("data", 36); b.writeUInt32LE(n * nch * 4, 40);
  for (let i = 0, p = 44; i < n; i++) for (let c = 0; c < nch; c++, p += 4) b.writeFloatLE(channels[c][i] || 0, p);
  fs.writeFileSync(path, b);
}

// ---------- the schedule (mirrors Spike/CallAudio/lab/main.mm) ----------
// seconds: [quiet, far only, near only, both, quiet]
export function boundaries(seconds) {
  const b = [0];
  for (const s of seconds) b.push(b[b.length - 1] + Math.floor(s * RATE));
  return b;
}
const FADE = 2400;
const fade = (k, len) => (k < FADE ? k / FADE : len - k < FADE ? (len - k) / FADE : 1);
export function scheduled(source, b, which) {
  const out = new Float32Array(b[5]);
  if (!source || !source.length) return out;
  for (let p = 0; p < b[5]; p++) {
    let g = 0, pos = 0;
    if (which === "far") {
      if (p >= b[1] && p < b[2]) { pos = p - b[1]; g = fade(p - b[1], b[2] - b[1]); }
      else if (p >= b[3] && p < b[4]) { pos = b[2] - b[1] + (p - b[3]); g = fade(p - b[3], b[4] - b[3]); }
    } else {
      if (p >= b[2] && p < b[3]) { pos = p - b[2]; g = fade(p - b[2], b[3] - b[2]); }
      else if (p >= b[3] && p < b[4]) { pos = b[3] - b[2] + (p - b[3]); g = fade(p - b[3], b[4] - b[3]); }
    }
    if (g > 0) out[p] = g * source[pos % source.length];
  }
  return out;
}

// ---------- basics ----------
export const db = (p) => 10 * Math.log10(p + 1e-15);
export function power(x, a, b) {
  a = Math.max(0, Math.floor(a)); b = Math.min(x.length, Math.floor(b));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += x[i] * x[i];
  return s / (b - a);
}
export function frameLevels(x, frame = 480) {
  const n = Math.floor(x.length / frame), out = new Float64Array(n);
  for (let f = 0; f < n; f++) out[f] = db(power(x, f * frame, (f + 1) * frame));
  return out;
}

// Active speech level (a light ITU P.56): mean power of 10 ms frames within 25 dB of the loud end.
export function activeLevel(x, a, b) {
  const lv = frameLevels(x.subarray(Math.max(0, a), Math.min(x.length, b)));
  if (!lv.length) return { level: -150, activeFraction: 0 };
  const sorted = [...lv].sort((p, q) => p - q), top = sorted[Math.floor(sorted.length * 0.95)];
  const thr = Math.max(top - 25, -70);
  let s = 0, n = 0;
  for (const l of lv) if (l >= thr) { s += 10 ** (l / 10); n++; }
  return { level: n ? db(s / n) : -150, activeFraction: n / lv.length };
}

// ---------- FFT and coherence ----------
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ar = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci, ai = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k + len / 2] = re[i + k] - ar; im[i + k + len / 2] = im[i + k] - ai;
        re[i + k] += ar; im[i + k] += ai;
        const t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
      }
    }
  }
}
const NFFT = 4096, HOP = 2048;
const HANN = Float64Array.from({ length: NFFT }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / NFFT));
const LO = Math.floor((100 * NFFT) / RATE), HI = Math.floor((7000 * NFFT) / RATE);

// Spectra of x over [a, b), cached per (signal, a, b) since lag scans reuse them.
function spectra(x, a, b) {
  const frames = [];
  for (let s = a; s + NFFT <= b; s += HOP) {
    const re = new Float64Array(NFFT), im = new Float64Array(NFFT);
    for (let i = 0; i < NFFT; i++) { const v = s + i >= 0 && s + i < x.length ? x[s + i] : 0; re[i] = v * HANN[i]; }
    fft(re, im);
    frames.push([re.slice(0, NFFT / 2 + 1), im.slice(0, NFFT / 2 + 1)]);
  }
  return frames;
}

// How much of x's power in [a, b) is linearly explained by stimulus s delayed by `lag` samples
// (magnitude-squared coherence, 100 Hz to 7 kHz, bias-corrected). Room noise and the near-end voice
// don't count as echo here, unlike a plain level difference.
export function coherentPower(x, s, a, b, lag, cacheX) {
  const X = cacheX || spectra(x, a, b), S = spectra(s, a - lag, b - lag);
  const K = Math.min(X.length, S.length);
  if (K < 4) return { power: 0, fraction: 0 };
  let explained = 0, total = 0;
  for (let k = LO; k <= HI; k++) {
    let sxx = 0, sss = 0, sr = 0, si = 0;
    for (let f = 0; f < K; f++) {
      const [xr, xi] = X[f], [tr, ti] = S[f];
      sxx += xr[k] * xr[k] + xi[k] * xi[k];
      sss += tr[k] * tr[k] + ti[k] * ti[k];
      sr += xr[k] * tr[k] + xi[k] * ti[k];
      si += xi[k] * tr[k] - xr[k] * ti[k];
    }
    let c = sss > 0 && sxx > 0 ? (sr * sr + si * si) / (sxx * sss) : 0;
    c = Math.max(0, (c - 1 / K) / (1 - 1 / K));
    explained += c * sxx;
  }
  for (let f = 0; f < K; f++) { const [xr, xi] = X[f]; for (let k = 0; k <= NFFT / 2; k++) total += xr[k] * xr[k] + xi[k] * xi[k]; }
  const fraction = total > 0 ? explained / total : 0;
  return { power: fraction * power(x, a, b), fraction };
}

// The stimulus delay (in samples) that explains the most of x in [a, b): lags from lo to hi ms.
export function findLag(x, s, a, b, loMs, hiMs) {
  const X = spectra(x, a, b);
  const scan = (from, to, step, best) => {
    for (let ms = from; ms <= to; ms += step) {
      const lag = Math.round((ms * RATE) / 1000), r = coherentPower(x, s, a, b, lag, X);
      if (r.power > best.power) best = { lag, ms, ...r };
    }
    return best;
  };
  // Coarse, then fine around the best.
  let best = scan(loMs, hiMs, 40, { lag: Math.round((loMs * RATE) / 1000), ms: loMs, power: 0, fraction: 0 });
  best = scan(best.ms - 40, best.ms + 40, 5, best);
  return best;
}

// Pearson correlation of 10 ms power envelopes (for telling device inputs apart), best over lags.
function envelope(x, rate, a, b) {
  const frame = Math.round(rate / 100), out = [];
  for (let s = Math.floor(a); s + frame <= b; s += frame) out.push(power(x, s, s + frame));
  return out;
}
function pearson(p, q) {
  const n = Math.min(p.length, q.length);
  if (n < 10) return 0;
  let mp = 0, mq = 0;
  for (let i = 0; i < n; i++) { mp += p[i]; mq += q[i]; }
  mp /= n; mq /= n;
  let sp = 0, sq = 0, spq = 0;
  for (let i = 0; i < n; i++) { const dp = p[i] - mp, dq = q[i] - mq; sp += dp * dp; sq += dq * dq; spq += dp * dq; }
  return sp > 0 && sq > 0 ? spq / Math.sqrt(sp * sq) : 0;
}
// x is at the device rate; the stimulus sits `centreSec` later in x than in its own timeline.
export function envelopeCorrelation(x, rate, stim, aSec, bSec, centreSec) {
  const ex = envelope(x, rate, aSec * rate, bSec * rate);
  let best = 0;
  for (let lagMs = -150; lagMs <= 150; lagMs += 10) {
    const l = centreSec + lagMs / 1000;
    const es = envelope(stim, RATE, (aSec - l) * RATE, (bSec - l) * RATE);
    best = Math.max(best, pearson(ex, es));
  }
  return best;
}

// ---------- one subject ----------
// rec: { sent: Float32Array (48 kHz), raw?: Float32Array, channels?: {rate, channels: Float32Array[]}, meta? }
// stim: { far, near } scheduled stimuli; seconds: schedule; opts: { nearLagMs: [lo, hi], farLagMs: [lo, hi] }
export function analyze(rec, stim, seconds, opts = {}) {
  const b = boundaries(seconds), x = rec.sent, S = RATE;
  const has = { far: b[2] > b[1], near: b[3] > b[2], dt: b[4] > b[3] };
  const out = { seconds };

  // Where the far end and the talker sit in the recording: x[t] ~ stimulus[t - lag]. The recording and
  // the players don't start together (the mic can start half a second after the speakers, a browser's
  // talker a second later), so find each by coherence, in the middle of its own segment.
  const farLagRange = opts.farLagMs || [-3000, 1500], nearLagRange = opts.nearLagMs || [-3000, 3000];
  const mid = (a, z) => { const m = Math.min(3 * S, (z - a) / 3); return [a + m, z - m]; };
  const farLag = has.far ? findLag(rec.raw || x, stim.far, ...mid(b[1], b[2]), ...farLagRange) : { lag: 0 };
  const nearLag = has.near ? findLag(rec.raw || x, stim.near, ...mid(b[2], b[3]), ...nearLagRange) : { lag: farLag.lag };
  const F = farLag.lag, N = nearLag.lag;
  out.farLagMs = (F * 1000) / S;
  out.nearLagMs = (N * 1000) / S;

  // Segment windows in the recording, each clear of the other source's edges.
  const lo = (...v) => Math.max(...v), hi = (...v) => Math.min(...v);
  const q0 = lo(0.5 * S, b[0] + F + 0.5 * S), q1 = hi(b[1] + F, b[2] + N) - 0.3 * S;
  const f0 = b[1] + F + 0.4 * S, f1 = hi(b[2] + F, b[2] + N) - 0.1 * S;
  const n0 = lo(b[2] + N, b[2] + F) + 0.4 * S, n1 = hi(b[3] + N, b[3] + F) - 0.1 * S;
  const d0 = lo(b[3] + N, b[3] + F) + 0.4 * S, d1 = hi(b[4] + N, b[4] + F) - 0.1 * S;
  const e0 = lo(b[4] + N, b[4] + F) + 0.3 * S, e1 = hi(b[5] + F, x.length) - 0.1 * S;
  out.windows = { quiet: [q0 / S, q1 / S], far: [f0 / S, f1 / S], near: [n0 / S, n1 / S], both: [d0 / S, d1 / S] };

  out.floorDb = db(power(x, q0, q1));
  out.floorEndDb = e1 > e0 ? db(power(x, e0, e1)) : null;

  // Near end alone: what the other side hears of you.
  if (has.near) {
    const a = n0, z = n1;
    const asl = activeLevel(x, a, z);
    let peak = 0, clipped = 0;
    for (let i = Math.floor(a); i < Math.min(z, x.length); i++) { const v = Math.abs(x[i]); if (v > peak) peak = v; if (v >= 0.999) clipped++; }
    out.sendLevelDb = asl.level;
    out.sendActive = asl.activeFraction;
    out.peakDb = 20 * Math.log10(peak + 1e-12);
    out.clippedPct = (100 * clipped) / Math.max(1, z - a);
    // Gain pumping: spread of (sent level - talker level) over 1 s windows where the talker is talking.
    const diffs = [];
    for (let w = a; w + RATE <= z; w += RATE) {
      const st = activeLevel(stim.near, w - nearLag.lag, w - nearLag.lag + RATE);
      if (st.activeFraction < 0.5) continue;
      diffs.push(activeLevel(x, w, w + RATE).level - st.level);
    }
    out.pumpingDb = diffs.length > 2 ? Math.sqrt(diffs.reduce((s, d, _, arr) => s + (d - arr.reduce((p, q) => p + q, 0) / arr.length) ** 2, 0) / diffs.length) : null;
    out.nearAloneCoherentDb = db(coherentPower(x, stim.near, a, z, nearLag.lag).power);
    if (rec.raw) {
      out.rawSendLevelDb = activeLevel(rec.raw, a, z).level;
      out.voiceKeptDb = out.sendLevelDb - out.rawSendLevelDb;
    }
  }

  // Far end alone: echo leak.
  if (has.far) {
    const lvl = db(power(x, f0, f1));
    out.echoAboveQuietDb = lvl - out.floorDb;
    out.windows5s = [];
    for (let w = f0; w + 5 * RATE <= f1 + 1; w += 5 * RATE) out.windows5s.push(+(db(power(x, w, w + 5 * RATE)) - out.floorDb).toFixed(1));
    out.firstWindowDb = out.windows5s[0] ?? null;
    out.worstLaterWindowDb = out.windows5s.length > 1 ? Math.max(...out.windows5s.slice(1)) : null;
    const coh = coherentPower(x, stim.far, f0, f1, farLag.lag);
    // Does what's left follow the far end's rhythm? Catches residual echo the coherence can't (speaker
    // distortion, the suppressor's leftovers), and tells it apart from room noise that happens to be there.
    out.echoRhythm = envelopeCorrelation(x, RATE, stim.far, f0 / S, f1 / S, F / S);
    out.echoCoherentDb = db(coh.power);
    out.echoCoherentAboveQuietDb = out.echoCoherentDb - out.floorDb;
    out.echoToSpeechDb = out.sendLevelDb != null ? out.echoCoherentDb - out.sendLevelDb : null;
    if (rec.raw) {
      // How loud you are at the mic against the far end's echo there: talk-over results depend on it.
      out.nearToEchoAtMicDb = out.rawSendLevelDb != null ? out.rawSendLevelDb - activeLevel(rec.raw, f0, f1).level : null;
      const roomCoh = coherentPower(rec.raw, stim.far, f0, f1, F);
      out.roomEchoDb = db(roomCoh.power);
      out.roomEchoAboveQuietDb = db(power(rec.raw, f0, f1)) - db(power(rec.raw, q0, q1));
      out.echoRemovedDb = out.roomEchoDb - out.echoCoherentDb;
    }
  }

  // Both talking.
  if (has.dt) {
    const a = d0, z = d1;
    const nearDt = coherentPower(x, stim.near, a, z, nearLag.lag), farDt = coherentPower(x, stim.far, a, z, farLag.lag);
    out.dtNearCoherentDb = db(nearDt.power);
    out.dtEchoCoherentDb = db(farDt.power);
    out.talkOverKeptDb = out.nearAloneCoherentDb != null ? out.dtNearCoherentDb - out.nearAloneCoherentDb : null;
    out.dtEchoToSpeechDb = out.dtEchoCoherentDb - out.dtNearCoherentDb;
    out.dtLevelDb = db(power(x, a, z));
  }

  // Level over time for the report: 100 ms frames of sent (and raw), plus stimulus activity.
  out.strip = {
    frameSec: 0.1,
    sent: Array.from(frameLevels(x, 4800), (v) => +v.toFixed(1)),
    raw: rec.raw ? Array.from(frameLevels(rec.raw, 4800), (v) => +v.toFixed(1)) : null,
    far: Array.from(frameLevels(stim.far, 4800), (v) => +v.toFixed(1)),
    near: Array.from(frameLevels(stim.near, 4800), (v) => +v.toFixed(1)),
    boundaries: b.map((v) => (v + F) / RATE),
  };

  // Device inputs: level per segment, and whether each one follows the far end or the talker.
  if (rec.channels) {
    // channels.wav starts with the raw mic (same capture), so the same windows apply.
    const { rate, channels } = rec.channels, w = out.windows;
    out.inputs = channels.map((c, i) => {
      const seg = ([s0, s1]) => db(power(c, s0 * rate, s1 * rate));
      const floor = seg(w.quiet), far = has.far ? seg(w.far) : null, near = has.near ? seg(w.near) : null;
      const farCorr = has.far ? envelopeCorrelation(c, rate, stim.far, ...w.far, F / S) : null;
      const nearCorr = has.near ? envelopeCorrelation(c, rate, stim.near, ...w.near, N / S) : null;
      let role = "quiet";
      if (floor < -120 && (far ?? -150) < -120 && (near ?? -150) < -120) role = "silent";
      else if (farCorr > 0.85 && far - floor > 25 && (near == null || nearCorr < 0.5)) role = "loopback of the far end";
      else if ((nearCorr ?? 0) > 0.5 || (farCorr ?? 0) > 0.5) role = "live mic";
      return { input: i + 1, floorDb: floor, farDb: far, nearDb: near, farCorrelation: farCorr, nearCorrelation: nearCorr, role };
    });
  }
  return out;
}

// ---------- verdicts ----------
const band = (v, good, warn, lowerIsBetter = true) => v == null || !isFinite(v) ? "na" : lowerIsBetter ? (v <= good ? "good" : v <= warn ? "warn" : "bad") : (v >= good ? "good" : v >= warn ? "warn" : "bad");
export const METRICS = [
  { key: "echoAboveQuietDb", label: "Echo (level above quiet)", unit: "dB", grade: (v) => band(v, 3, 10), help: "Far end only: how much louder the sent audio gets. Under 3 dB good, over 10 dB the other side hears themselves." },
  { key: "echoRhythm", label: "Leftover follows far end", unit: "0–1", grade: (v) => band(v, 0.2, 0.4), help: "How closely what's sent in the far-end-only stretch follows the far end's rhythm (envelope correlation). Low: any level rise there is room noise, not echo. High: echo is getting through, even if distorted." },
  { key: "echoToSpeechDb", label: "Echo vs your voice (correlated)", unit: "dB", grade: (v) => band(v, -30, -20), help: "Far-end recording found inside the sent audio, against your speech level. Noise can't fake it." },
  { key: "dtEchoToSpeechDb", label: "Echo while both talk", unit: "dB", grade: (v) => band(v, -25, -15), help: "Same, during double-talk, against your voice in the same stretch." },
  { key: "talkOverKeptDb", label: "Your voice kept in talk-over", unit: "dB", grade: (v) => band(v, -3, -8, false), help: "Your voice while both talk, against your voice alone. 0 dB is untouched; below -8 dB you get chopped." },
  { key: "sendLevelDb", label: "Send level (active speech)", unit: "dBFS", grade: (v) => (v == null ? "na" : v >= -32 && v <= -18 ? "good" : v >= -42 && v <= -12 ? "warn" : "bad"), help: "Your speech level as sent. Around -26 dBFS is typical." },
  { key: "peakDb", label: "Peak", unit: "dBFS", grade: (v) => band(v, -3, -0.5), help: "Loudest sample of your speech." },
  { key: "clippedPct", label: "Clipped", unit: "%", grade: (v) => band(v, 0, 0.1), help: "Share of samples at full scale." },
  { key: "pumpingDb", label: "Gain pumping", unit: "dB", grade: (v) => band(v, 2, 4), help: "How much the send level wanders against the talker's own level (1 s windows)." },
  { key: "floorDb", label: "Noise floor sent", unit: "dBFS", grade: (v) => band(v, -60, -50), help: "Sent level in the quiet at the start." },
];
export function grade(result) {
  const g = {};
  for (const m of METRICS) g[m.key] = m.grade(result[m.key]);
  return g;
}
