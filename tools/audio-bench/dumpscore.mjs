// Scores a call audio dump (raw.wav, ref.wav, sent.wav, meta.json: what the patched WebKit unit writes with
// BROWSA_CALL_AUDIO_DUMP, or a native Audio Lab recording in the same layout) by the guest's ear, with no
// knowledge of what anyone said.
//
// In a real call there is no known near-end talker signal, so only some figures mean anything:
//   - Echo, judged on stretches where the far end talks and you don't ("far only"). Found automatically:
//     the far end (ref.wav, exactly what the speakers played) is active and the mic is mostly explained by it
//     (coherence) or hears nothing above the room. The guest's-ear figures (G.131 margin, % of their speech
//     with audible echo, echo loss) come from these stretches only.
//   - Your send level, from stretches where only you talk (far end silent, mic well above the room), and how
//     much of your voice the processing kept there (sent level against raw mic level).
//   - Not measurable without a known talker: talk-over (double talk) and gain pumping. Mixed stretches are
//     counted, not scored.
// Plain Node, no dependencies.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { RATE, db, power, activeLevel, coherentPower, findLag, guestEar, readWav, writeWavFloat } from "./analyze.mjs";

export function loadDump(dir) {
  const read = (name) => (fs.existsSync(path.join(dir, name)) ? readWav(path.join(dir, name)) : null);
  const raw = read("raw.wav"), ref = read("ref.wav"), sent = read("sent.wav");
  if (!raw || !ref) throw new Error(`${dir}: needs raw.wav and ref.wav`);
  for (const [n, w] of [["raw", raw], ["ref", ref], ["sent", sent]]) if (w && w.rate !== RATE) throw new Error(`${dir}/${n}.wav: not ${RATE} Hz`);
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")); } catch {}
  const n = Math.min(raw.channels[0].length, ref.channels[0].length, sent ? sent.channels[0].length : Infinity);
  return { dir, raw: raw.channels[0].subarray(0, n), ref: ref.channels[0].subarray(0, n), sent: sent ? sent.channels[0].subarray(0, n) : null, meta };
}

const BLOCK = 2 * RATE, STEP = RATE / 2;

// The echo path: how much later the far end shows up in the mic than in ref.wav (the unit already lines the
// reference up with the mic, so this is small: the acoustic path less the reference lead).
export function echoLag(raw, ref) {
  // The 30 s with the most far-end activity.
  const span = Math.min(30 * RATE, raw.length), act = refActivity(ref);
  let best = 0, bestAt = 0;
  for (let a = 0; a + span <= raw.length; a += 5 * RATE) {
    let s = 0;
    for (let i = Math.floor(a / 480); i < Math.floor((a + span) / 480); i++) s += act.frames[i] ? 1 : 0;
    if (s > best) { best = s; bestAt = a; }
  }
  if (!best) return { lag: 0, ms: 0, fraction: 0, found: false };
  const r = findLag(raw, ref, bestAt, bestAt + span, -100, 300);
  return { ...r, found: r.fraction > 0.02 };
}

function refActivity(ref) {
  const lv = [];
  for (let f = 0; (f + 1) * 480 <= ref.length; f++) lv.push(db(power(ref, f * 480, (f + 1) * 480)));
  const level = activeLevel(ref, 0, ref.length).level;
  const thr = Math.max(level - 20, -70);
  return { level, thr, frames: lv.map((l) => l >= thr) };
}

// Classify overlapping 2 s blocks (0.5 s apart), then merge into stretches.
export function detectStretches(raw, ref, lag) {
  const act = refActivity(ref);
  const blocks = [];
  for (let a = 0; a + BLOCK <= raw.length; a += STEP) blocks.push({ a, rawDb: db(power(raw, a, a + BLOCK)) });
  if (!blocks.length) return { far: [], near: [], counts: {}, floorDb: -150 };
  for (const b of blocks) {
    let on = 0, n = 0;
    for (let i = Math.floor(b.a / 480); i < Math.floor((b.a + BLOCK) / 480); i++, n++) on += act.frames[i] ? 1 : 0;
    b.refActive = on / Math.max(1, n);
  }
  // The room at the mic: among blocks where the far end is silent (all blocks if too few), the third quietest
  // or the quietest tenth, whichever is lower (a call can have only a few seconds of nobody talking), ignoring
  // digital silence.
  const silent = blocks.filter((b) => b.refActive <= 0.05 && b.rawDb > -100);
  const pool = (silent.length >= 3 ? silent : blocks.filter((b) => b.rawDb > -100)).map((b) => b.rawDb).sort((p, q) => p - q);
  const rawFloor = pool.length ? pool[Math.min(2, Math.floor(pool.length * 0.1))] : -100;
  for (const b of blocks) {
    b.kind = "mixed";
    if (b.refActive >= 0.3) {
      const quietMic = b.rawDb < rawFloor + 6;
      const coh = quietMic ? null : coherentPower(raw, ref, b.a, b.a + BLOCK, lag);
      b.explained = coh ? coh.fraction : null;
      if (quietMic || coh.fraction >= 0.5) b.kind = "far";
    } else if (b.refActive <= 0.05) {
      b.kind = b.rawDb > rawFloor + 10 ? "near" : b.rawDb < rawFloor + 4 ? "quiet" : "mixed";
    }
  }
  // Each block labels its central half second; runs of one label become stretches (2 s or longer).
  const label = (kind) => {
    const out = [];
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].kind !== kind) continue;
      let j = i;
      while (j + 1 < blocks.length && blocks[j + 1].kind === kind) j++;
      const a = blocks[i].a + 0.75 * RATE, z = blocks[j].a + 1.25 * RATE;
      if (z - a >= 2 * RATE) out.push([a, z]);
      i = j;
    }
    return out;
  };
  const counts = {};
  for (const b of blocks) counts[b.kind] = (counts[b.kind] || 0) + 1;
  return { far: label("far"), near: label("near"), quiet: label("quiet"), counts, rawFloorDb: rawFloor, refLevelDb: act.level };
}

const concat = (x, spans, shift = 0) => {
  const len = spans.reduce((s, [a, z]) => s + Math.floor(z) - Math.floor(a), 0), out = new Float32Array(len);
  let p = 0;
  for (const [a, z] of spans) for (let i = Math.floor(a); i < Math.floor(z); i++, p++) { const j = i - shift; out[p] = j >= 0 && j < x.length ? x[j] : 0; }
  return out;
};
const seconds = (spans) => spans.reduce((s, [a, z]) => s + (z - a), 0) / RATE;

// Scores one sent signal against the dump's far end, on stretches found once per dump (pass them in to score
// several replays the same way). opts.guest: guestEar options (oneWayMs etc.).
export function scoreSent(sent, ref, raw, st, lag, opts = {}) {
  const out = { farOnlySec: +seconds(st.far).toFixed(1), nearOnlySec: +seconds(st.near).toFixed(1), quietSec: +seconds(st.quiet).toFixed(1) };
  // The room as sent: quiet stretches if any, else the quietest tenth of the sent signal.
  if (st.quiet.length) out.floorDb = db(power(concat(sent, st.quiet), 0, Infinity));
  else {
    const lv = [];
    for (let a = 0; a + RATE <= sent.length; a += RATE) lv.push(db(power(sent, a, a + RATE)));
    lv.sort((p, q) => p - q);
    out.floorDb = lv.length ? lv[Math.floor(lv.length * 0.1)] : -150;
  }
  if (st.far.length) {
    const x = concat(sent, st.far), s = concat(ref, st.far, lag), len = x.length;
    const coh = coherentPower(x, s, 0, len, 0);
    const g = guestEar(x, s, 0, { far: [0, len / RATE], both: [0, 0] }, out.floorDb, { ...opts.guest, overallEchoDb: { far: db(coh.power) }, overallLimitDb: { far: db(coh.limit) } });
    const f = g.segments.far || {};
    Object.assign(out, {
      margin: f.g131Margin != null ? +f.g131Margin.toFixed(1) : null, marginIsLowerBound: !!f.echoLossIsLowerBound,
      audiblePct: f.audiblePct ?? null, annoyingPct: f.annoyingPct ?? null, echoLossDb: f.echoLossDb != null ? +f.echoLossDb.toFixed(1) : null,
      worst: f.worst || null, echoAboveFloorDb: +(db(coh.power) - out.floorDb).toFixed(1), blocks: g.blocks,
    });
  }
  if (st.near.length) {
    const x = concat(sent, st.near), r = concat(raw, st.near);
    out.sendLevelDb = +activeLevel(x, 0, x.length).level.toFixed(1);
    out.rawLevelDb = +activeLevel(r, 0, r.length).level.toFixed(1);
    out.voiceKeptDb = +(out.sendLevelDb - out.rawLevelDb).toFixed(1);
  }
  out.floorDb = +out.floorDb.toFixed(1);
  return out;
}

// One number to rank settings by (higher is better): the G.131 margin, capped at 20 (beyond that the guest hears
// nothing either way), less 0.25 per % of the guest's speech with audible echo (moments the overall margin hides),
// less a penalty when your voice would be sent too quiet or too loud (nominal -26 dBFS active level, no penalty
// within 6 dB of it). Without far-only stretches there is nothing to rank.
export function rank(score) {
  if (score.margin == null) return null;
  let r = Math.min(score.margin, 20) - 0.25 * (score.audiblePct || 0);
  if (score.sendLevelDb != null) r -= 0.5 * Math.max(0, Math.abs(score.sendLevelDb + 26) - 6);
  return +r.toFixed(2);
}

export function describe(score) {
  if (score.margin == null) return `no far-only stretches to judge (far ${score.farOnlySec} s)`;
  const m = `${score.marginIsLowerBound ? "≥" : ""}${score.margin}`;
  return `G.131 f ${m} (14+ fine, 8- annoying), echo audible in ${score.audiblePct}% of their speech, echo loss ${score.echoLossDb} dB` +
    (score.sendLevelDb != null ? `, your voice sent at ${score.sendLevelDb} dBFS` : "") + ` [far-only ${score.farOnlySec} s, you-only ${score.nearOnlySec} s]`;
}

// ---------- clips ----------
export function m4a(x, file) {
  const wav = file.replace(/\.m4a$/, ".tmp.wav");
  writeWavFloat(wav, [x], RATE);
  try { execFileSync("afconvert", ["-f", "m4af", "-d", "aac", "-b", "64000", "-c", "1", wav, file]); } finally { fs.rmSync(wav, { force: true }); }
}
// Stretches end to end with 0.3 s of silence between, at most `maxSec`.
export function joined(x, spans, gain = 1, maxSec = 90) {
  const gap = Math.floor(0.3 * RATE), parts = [];
  let total = 0;
  for (const [a, z] of spans) {
    const n = Math.min(Math.floor(z) - Math.floor(a), maxSec * RATE - total);
    if (n <= 0) break;
    parts.push([Math.floor(a), n]);
    total += n + gap;
  }
  const out = new Float32Array(Math.max(0, total));
  let p = 0;
  for (const [a, n] of parts) {
    for (let i = 0; i < n; i++) out[p + i] = Math.max(-1, Math.min(1, x[a + i] * gain));
    p += n + gap;
  }
  return out;
}

