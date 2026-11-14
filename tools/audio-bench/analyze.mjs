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
  const fraction = total > 0 ? explained / total : 0, p = power(x, a, b);
  // Twice what chance coherence over K frames gives: a smaller "explained" power can't be told from none.
  return { power: fraction * p, fraction, limit: (2 / K) * p };
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
    out.echoCoherentLimitDb = db(coh.limit);
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
    // While both talk, model the sent signal from both known sources, so your voice doesn't hide the echo.
    const two = twoSourceSegment(x, stim.far, stim.near, a, z, farLag.lag, nearLag.lag);
    out.dtEchoCoherentDb = db(two.power);
    out.dtEchoCoherentLimitDb = db(two.limit);
    out.dtEchoSingleSourceDb = db(farDt.power);
    out.talkOverKeptDb = out.nearAloneCoherentDb != null ? out.dtNearCoherentDb - out.nearAloneCoherentDb : null;
    out.dtEchoToSpeechDb = out.dtEchoCoherentDb - out.dtNearCoherentDb;
    out.dtLevelDb = db(power(x, a, z));
  }

  // The guest's ear: their own voice coming back to them.
  if (has.far) {
    out.guest = guestEar(x, stim.far, F, out.windows, out.floorDb, { ...opts.guest, stimNear: stim.near, nearLag: nearLag.lag, overallEchoDb: { far: out.echoCoherentDb, both: out.dtEchoCoherentDb }, overallLimitDb: { far: out.echoCoherentLimitDb, both: out.dtEchoCoherentLimitDb } });
    const g = out.guest.segments;
    out.guestAudiblePct = g.far?.audiblePct ?? null;
    out.guestDtAudiblePct = g.both?.audiblePct ?? null;
    out.guestMargin = g.far?.g131Margin ?? null;
    out.guestWorstLossDb = g.far?.worst?.lossDb ?? null;
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
  { key: "guestAudiblePct", label: "Guest hears own echo", unit: "% of their speech", grade: (v) => band(v, 0, 5), help: "Far end only: share of the other person's speech (200 ms blocks) whose echo comes back above the noise and louder than the ITU-T G.131 'acceptable' talker-echo limit for the assumed delay. Faint, intermittent leak shows up here." },
  { key: "guestDtAudiblePct", label: "…while both talk", unit: "%", grade: (v) => band(v, 0, 10), help: "The same while you both talk." },
  { key: "guestMargin", label: "G.131 margin", unit: "f", grade: (v) => band(v, 14, 8, false), help: "ITU-T G.131 f(T, TELR) over the far-end stretch: 14 or more is above the 'acceptable' curve, 8 or less below the 'limiting case' (annoying)." },
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

// ---------- the guest's ear: does the other person hear their own voice come back? ----------
//
// Talker echo is judged by ITU-T G.131 (11/2003) clause 3, rule "derived from formula 3-22/G.107"
// (the same expression as G.107 (06/2015) eq. 7-22 for TERV):
//   f(T, TELR) = TELR - 40 log10((1 + T/10) / (1 + T/150)) + 6 exp(-0.3 T^2)
//   f >= 14: above the "acceptable" curve, not annoying; 8 < f < 14: probably annoying; f <= 8: below the
//   "limiting case" curve, annoying. T: mean one-way transmission time in ms (half the talker's
//   mouth-to-ear round trip). G.131 notes "acceptable" corresponds to E-model R = 74, "limiting" to R = 60.
// TELR = SLR + RLR + echo loss (G.131 clause 3, "TELR = SLR + RLR + Le"). Here the echo loss is measured
// digitally: the far end's level as it arrives at Browsa against the level of the far-end-correlated
// signal Browsa sends back (a terminal coupling loss). SLR + RLR default to G.107's 8 + 2 dB.
export function telrRequired(T, f) {
  return f + 40 * Math.log10((1 + T / 10) / (1 + T / 150)) - 6 * Math.exp(-0.3 * T * T);
}
export function g131Margin(T, telr) {
  return telr - 40 * Math.log10((1 + T / 10) / (1 + T / 150)) + 6 * Math.exp(-0.3 * T * T);
}

// Far-end-correlated power in x, per FFT frame, from coherence over a sliding ~1 s neighbourhood.
function frameEcho(x, s, a, z, lag, half = 11) {
  const X = spectra(x, a, z), S = spectra(s, a - lag, z - lag), K = Math.min(X.length, S.length);
  const nb = NFFT / 2 + 1, out = new Float64Array(K), limit = new Float64Array(K);
  // Per-frame auto and cross spectra in the band.
  const sxx = [], sss = [], sr = [], si = [], tot = new Float64Array(K);
  for (let f = 0; f < K; f++) {
    const [xr, xi] = X[f], [tr, ti] = S[f];
    const a1 = new Float64Array(nb), a2 = new Float64Array(nb), c1 = new Float64Array(nb), c2 = new Float64Array(nb);
    for (let k = 0; k < nb; k++) {
      a1[k] = xr[k] * xr[k] + xi[k] * xi[k];
      tot[f] += a1[k];
      if (k < LO || k > HI) continue;
      a2[k] = tr[k] * tr[k] + ti[k] * ti[k];
      c1[k] = xr[k] * tr[k] + xi[k] * ti[k];
      c2[k] = xi[k] * tr[k] - xr[k] * ti[k];
    }
    sxx.push(a1); sss.push(a2); sr.push(c1); si.push(c2);
  }
  for (let f = 0; f < K; f++) {
    const f0 = Math.max(0, f - half), f1 = Math.min(K - 1, f + half), n = f1 - f0 + 1;
    let explained = 0;
    for (let k = LO; k <= HI; k++) {
      let A = 0, B = 0, R = 0, I = 0;
      for (let g = f0; g <= f1; g++) { A += sxx[g][k]; B += sss[g][k]; R += sr[g][k]; I += si[g][k]; }
      let c = A > 0 && B > 0 ? (R * R + I * I) / (A * B) : 0;
      c = Math.max(0, (c - 1 / n) / (1 - 1 / n));
      explained += c * sxx[f][k];
    }
    const start = a + f * HOP, p = power(x, start, start + NFFT);
    out[f] = tot[f] > 0 ? (explained / tot[f]) * p : 0;
    // What chance coherence over n frames alone would give: below about twice that, echo can't be told
    // apart from the rest of the sent signal (the near-end voice, while both talk).
    limit[f] = (2 / n) * p;
  }
  return { echo: out, limit };  // frame f covers [a + f*HOP, a + f*HOP + NFFT)
}

// opts: { oneWayMs (network, default 300), localMs (Browsa's own echo path, default 50), slrRlr (default 10),
//         blockSec (default 0.2) }
export function guestEar(x, stimFar, F, windows, floorDb, opts = {}) {
  const S = RATE, oneWay = opts.oneWayMs ?? 300, local = opts.localMs ?? 50, slrRlr = opts.slrRlr ?? 10, blockSec = opts.blockSec ?? 0.2;
  const T = oneWay + local / 2;  // mean one-way: half of (network out + back + Browsa's echo path)
  const need = { acceptable: telrRequired(T, 14) - slrRlr, limiting: telrRequired(T, 8) - slrRlr };
  const farActive = activeLevel(stimFar, 0, stimFar.length).level;
  const res = { T, oneWayMs: oneWay, localMs: local, slrRlr, requiredLossDb: need, segments: {}, blocks: [] };

  const segment = (name, [a0, a1]) => {
    const a = Math.floor(a0 * S), z = Math.floor(a1 * S);
    if (z - a < NFFT * 4) return;
    const { echo: fe, limit: fl } = name === "both" && opts.stimNear ? twoSourceFrames(x, stimFar, opts.stimNear, a, z, F, opts.nearLag) : frameEcho(x, stimFar, a, z, F);
    const framesPerBlock = Math.max(1, Math.round((blockSec * S) / HOP));
    let farBlocks = 0, audible = 0, annoying = 0, unmeasurable = 0, first = { far: 0, audible: 0 }, worst = null;
    let echoSum = 0, echoN = 0;
    for (let f = 0; f + framesPerBlock <= fe.length; f += framesPerBlock) {
      const start = a + f * HOP, end = start + framesPerBlock * HOP;
      let e = 0, lim = 0;
      for (let g = f; g < f + framesPerBlock; g++) { e += fe[g]; lim += fl[g]; }
      e /= framesPerBlock; lim /= framesPerBlock;
      const farDb = db(power(stimFar, start - F, end - F));
      if (farDb < farActive - 20) continue;  // the far end isn't talking in this block
      farBlocks++;
      const echoDb = db(e), loss = farDb - echoDb;
      echoSum += e; echoN++;
      const measurable = e > lim;
      if (!measurable) unmeasurable++;
      const aboveNoise = measurable && echoDb > floorDb;
      const isAudible = aboveNoise && loss < need.acceptable, isAnnoying = aboveNoise && loss < need.limiting;
      if (isAudible) audible++;
      if (isAnnoying) annoying++;
      const t = start / S;
      if (t < a0 + 5) { first.far++; if (isAudible) first.audible++; }
      if (aboveNoise && (!worst || loss < worst.lossDb)) worst = { t: +t.toFixed(2), echoDb: +echoDb.toFixed(1), lossDb: +loss.toFixed(1) };
      res.blocks.push({ t: +t.toFixed(2), seg: name, echoDb: +echoDb.toFixed(1), lossDb: +loss.toFixed(1), audible: isAudible, annoying: isAnnoying, measurable });
    }
    // The overall figure comes from coherence over the whole stretch (hundreds of frames, so chance coherence
    // is about 27 dB down rather than 10), not from the per-block estimates.
    const overallDb = opts.overallEchoDb?.[name];
    const limitDb = opts.overallLimitDb?.[name];
    // Below the measurement limit, report the loss the limit allows ("at least").
    const atLimit = overallDb != null && limitDb != null && overallDb < limitDb;
    const usedDb = atLimit ? limitDb : overallDb;
    // Like with like: the far end's mean power over the same stretch (pauses included) against the echo's.
    const farSegDb = db(power(stimFar, a - F, z - F));
    const overallLoss = usedDb != null && isFinite(usedDb) ? farSegDb - usedDb : echoN ? farActive - db(echoSum / echoN) : null;
    res.segments[name] = {
      farSpeechSec: +(farBlocks * framesPerBlock * HOP / S).toFixed(1),
      audibleSec: +(audible * framesPerBlock * HOP / S).toFixed(1),
      audiblePct: farBlocks ? +((100 * audible) / farBlocks).toFixed(1) : null,
      annoyingPct: farBlocks ? +((100 * annoying) / farBlocks).toFixed(1) : null,
      // Blocks where the echo, if any, was too far under the rest of the signal to measure (mostly while both talk).
      unmeasurablePct: farBlocks ? +((100 * unmeasurable) / farBlocks).toFixed(1) : null,
      first5sAudiblePct: first.far ? +((100 * first.audible) / first.far).toFixed(1) : null,
      afterAudiblePct: farBlocks - first.far ? +((100 * (audible - first.audible)) / (farBlocks - first.far)).toFixed(1) : null,
      echoLossDb: overallLoss,
      echoLossIsLowerBound: atLimit,
      telrDb: overallLoss != null ? overallLoss + slrRlr : null,
      g131Margin: overallLoss != null ? g131Margin(T, overallLoss + slrRlr) : null,
      worst,
    };
  };
  segment("far", windows.far);
  segment("both", windows.both);
  return res;
}

// Two known sources in one recording (both talking): per bin, least-squares fit of x to the far end and the
// talker together over K frames (a 2x2 cross-spectral solve), so the talker's voice no longer hides the
// echo. Returns the far-end part's power and the measurement limit set by what neither source explains.
// frames: optional [f0, f1) range of frames to sum (for time-resolved use); default all.
function spectraSet(x, far, near, a, b, lagFar, lagNear) {
  return { X: spectra(x, a, b), A: spectra(far, a - lagFar, b - lagFar), B: spectra(near, a - lagNear, b - lagNear) };
}
function twoSourceEcho(set, f0, f1, framePower) {
  const { X, A, B } = set;
  let echo = 0, resid = 0, total = 0;
  const K = f1 - f0;
  if (K < 4) return { power: 0, limit: 0 };
  for (let k = LO; k <= HI; k++) {
    let aa = 0, bb = 0, abr = 0, abi = 0, axr = 0, axi = 0, bxr = 0, bxi = 0, xx = 0;
    for (let f = f0; f < f1; f++) {
      const [xr, xi] = X[f], [ar, ai] = A[f], [br, bi] = B[f];
      aa += ar[k] * ar[k] + ai[k] * ai[k]; bb += br[k] * br[k] + bi[k] * bi[k]; xx += xr[k] * xr[k] + xi[k] * xi[k];
      // conj(a)*b, conj(a)*x, conj(b)*x
      abr += ar[k] * br[k] + ai[k] * bi[k]; abi += ar[k] * bi[k] - ai[k] * br[k];
      axr += ar[k] * xr[k] + ai[k] * xi[k]; axi += ar[k] * xi[k] - ai[k] * xr[k];
      bxr += br[k] * xr[k] + bi[k] * xi[k]; bxi += br[k] * xi[k] - bi[k] * xr[k];
    }
    // Solve [aa, ab; conj(ab), bb] [h1; h2] = [ax; bx]
    const det = aa * bb - (abr * abr + abi * abi);
    if (!(det > 0)) continue;
    // h1 = (bb*ax - ab*bx) / det
    const h1r = (bb * axr - (abr * bxr - abi * bxi)) / det, h1i = (bb * axi - (abr * bxi + abi * bxr)) / det;
    // h2 = (aa*bx - conj(ab)*ax) / det
    const h2r = (aa * bxr - (abr * axr + abi * axi)) / det, h2i = (aa * bxi - (abr * axi - abi * axr)) / det;
    const e1 = (h1r * h1r + h1i * h1i) * aa, e2 = (h2r * h2r + h2i * h2i) * bb;
    // cross term between the two modelled parts
    const cross = 2 * ((h1r * h2r + h1i * h2i) * abr - (h1r * h2i - h1i * h2r) * abi);
    const r = Math.max(0, xx - e1 - e2 - cross);
    echo += Math.max(0, e1 - r / K);  // bias: about one residual share per fitted source
    resid += r;
  }
  for (let f = f0; f < f1; f++) { const [xr, xi] = X[f]; for (let k = 0; k <= NFFT / 2; k++) total += xr[k] * xr[k] + xi[k] * xi[k]; }
  const scale = total > 0 ? framePower / total : 0;
  return { power: echo * scale, limit: (2 / K) * resid * scale };
}
export function twoSourceSegment(x, far, near, a, b, lagFar, lagNear) {
  const set = spectraSet(x, far, near, a, b, lagFar, lagNear), K = Math.min(set.X.length, set.A.length, set.B.length);
  return twoSourceEcho(set, 0, K, power(x, a, b));
}
export function twoSourceFrames(x, far, near, a, b, lagFar, lagNear, half = 11) {
  const set = spectraSet(x, far, near, a, b, lagFar, lagNear), K = Math.min(set.X.length, set.A.length, set.B.length);
  const echo = new Float64Array(K), limit = new Float64Array(K);
  for (let f = 0; f < K; f++) {
    const f0 = Math.max(0, f - half), f1 = Math.min(K, f + half + 1);
    const s0 = a + f0 * HOP, s1 = a + (f1 - 1) * HOP + NFFT;
    const r = twoSourceEcho(set, f0, f1, power(x, s0, s1));
    echo[f] = r.power; limit[f] = r.limit;
  }
  return { echo, limit };
}
