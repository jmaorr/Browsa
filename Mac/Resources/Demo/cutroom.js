// Cutroom: Browsa's demo video editor. A small, real editor: the timeline, viewer and grade all work by
// hand, and window.cutroom exposes the same edits (eased, so they read well on camera) for agents.

const FPS = 24;
const media = [
  { id: 'paella',     name: 'Pan on the fire',   len: 9 },
  { id: 'burrata',    name: 'Burrata, torn',     len: 7 },
  { id: 'chicken',    name: 'Out of the oven',   len: 8 },
  { id: 'salmon',     name: 'Glaze, close',      len: 6 },
  { id: 'risotto',    name: 'Risotto stir',      len: 8 },
  { id: 'peach',      name: 'Peaches on coals',  len: 10 },
  { id: 'shortrib',   name: 'Short rib, resting', len: 7 },
  { id: 'pannacotta', name: 'Panna cotta wobble', len: 6 },
];
const byId = Object.fromEntries(media.map(m => [m.id, m]));

const state = {
  // The cut: clips in order on V1, each a length of its source. Peaches runs long on purpose.
  clips: [
    { id: 'paella', dur: 4.5 }, { id: 'burrata', dur: 3.5 }, { id: 'peach', dur: 8.0 },
    { id: 'chicken', dur: 4.0 }, { id: 'pannacotta', dur: 4.0 },
  ],
  titles: [],                       // { id, at, dur, text, sub, style }
  grade: { lift: [0, 0], gamma: [0, 0], gain: [0, 0], temp: 0, sat: 100 },
  scale: 108,
  t: 0, playing: false, pps: 86,    // playhead seconds, pixels per second
  selected: null,                   // { kind: 'clip'|'title', id }
};

const $ = (s) => document.querySelector(s);
const images = {};
for (const m of media) { const img = new Image(); img.src = `/demo/img/supper-${m.id}.jpg`; img.onload = () => { draw(); renderBins(); renderTimeline(); }; images[m.id] = img; }

const total = () => state.clips.reduce((s, c) => s + c.dur, 0);
const starts = () => { let s = 0; return state.clips.map(c => { const v = s; s += c.dur; return v; }); };
const tc = (sec) => {
  const f = Math.round(sec * FPS), ff = f % FPS, s = Math.floor(f / FPS);
  return [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60, ff].map(n => String(n).padStart(2, '0')).join(':');
};
const ease = (x) => x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
function tween(ms, step) {
  return new Promise(done => {
    const t0 = performance.now();
    // Frames when they come; a timer backs them up when a hidden page gets none, so agent edits still finish.
    const next = (f) => {
      let ran = false;
      const go = () => { if (!ran) { ran = true; f(performance.now()); } };
      requestAnimationFrame(go); setTimeout(go, 40);
    };
    const tick = (now) => { const p = Math.min(1, (now - t0) / ms); step(ease(p)); p < 1 ? next(tick) : done(); };
    next(tick);
  });
}
let saveTimer;
function changed() {
  const el = $('#saved'); el.textContent = 'Saving…'; el.classList.add('busy');
  clearTimeout(saveTimer); saveTimer = setTimeout(() => { el.textContent = 'All changes saved'; el.classList.remove('busy'); }, 700);
}
function toast(text) {
  const el = $('#toast'); el.textContent = text; el.hidden = false;
  clearTimeout(toast.t); toast.t = setTimeout(() => { el.hidden = true; }, 1800);
}

// MARK: Media bin

function renderBins() {
  const used = new Set(state.clips.map(c => c.id));
  $('#bins').innerHTML = media.map(m => `
    <div class="bin" data-media="${m.id}">
      <div class="thumb${used.has(m.id) ? ' used' : ''}" style="background-image:url(/demo/img/supper-${m.id}.jpg)"><em>${tc(m.len).slice(3, 8)}</em></div>
      <span>${m.name}</span>
    </div>`).join('');
}

// MARK: Viewer

const canvas = $('#frame'), ctx = canvas.getContext('2d');
function clipAt(t) {
  const s = starts();
  for (let i = 0; i < state.clips.length; i++) if (t < s[i] + state.clips[i].dur || i === state.clips.length - 1) return { clip: state.clips[i], local: t - s[i], i };
  return null;
}
function draw() {
  const W = canvas.width, H = canvas.height, at = clipAt(state.t);
  ctx.save();
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
  if (at) {
    const img = images[at.clip.id];
    if (img.complete && img.naturalWidth) {
      // Ken Burns: a slow push-in across the clip, alternating direction.
      const p = Math.max(0, Math.min(1, at.local / Math.max(at.clip.dur, .01)));
      const z = state.scale / 100 * (1 + .06 * p), dir = at.i % 2 ? -1 : 1;
      const cover = Math.max(W / img.naturalWidth, H / img.naturalHeight) * z;
      const w = img.naturalWidth * cover, h = img.naturalHeight * cover;
      const g = state.grade;
      ctx.filter = `saturate(${g.sat}%) brightness(${100 + g.gain[1] * -10 + 2}%)`;
      ctx.drawImage(img, (W - w) / 2 + dir * (p - .5) * 60, (H - h) / 2, w, h);
      ctx.filter = 'none';
      gradeOverlay(W, H);
    }
  }
  ctx.restore();
  // Vignette, like a graded master.
  const v = ctx.createRadialGradient(W / 2, H / 2, H * .35, W / 2, H / 2, H * .95);
  v.addColorStop(0, 'rgba(0,0,0,0)'); v.addColorStop(1, 'rgba(0,0,0,.42)');
  ctx.fillStyle = v; ctx.fillRect(0, 0, W, H);
  renderTitles();
  $('#tc').textContent = tc(state.t);
  $('#dur').textContent = tc(total());
}
// A wheel offset [x, y] as an RGB tint: the hue at that angle, strength by distance from centre.
function wheelRGB([x, y]) {
  const a = Math.atan2(-y, x), m = Math.min(1, Math.hypot(x, y));
  const c = (k) => Math.round(255 * (.5 + .5 * Math.cos(a - k)));
  return { r: c(0), g: c(2.094), b: c(4.189), m };
}
function gradeOverlay(W, H) {
  const g = state.grade;
  // Temperature: warm amber or cool blue over everything.
  if (g.temp) {
    ctx.globalCompositeOperation = 'soft-light';
    ctx.fillStyle = g.temp > 0 ? `rgba(255,150,40,${g.temp / 100 * .55})` : `rgba(60,140,255,${-g.temp / 100 * .55})`;
    ctx.fillRect(0, 0, W, H);
  }
  // Lift tints the shadows, gamma the mids, gain the highlights.
  const lift = wheelRGB(g.lift), gamma = wheelRGB(g.gamma), gain = wheelRGB(g.gain);
  if (lift.m) { ctx.globalCompositeOperation = 'screen'; ctx.fillStyle = `rgba(${lift.r},${lift.g},${lift.b},${lift.m * .22})`; ctx.fillRect(0, 0, W, H); }
  if (gamma.m) { ctx.globalCompositeOperation = 'soft-light'; ctx.fillStyle = `rgba(${gamma.r},${gamma.g},${gamma.b},${gamma.m * .6})`; ctx.fillRect(0, 0, W, H); }
  if (gain.m) { ctx.globalCompositeOperation = 'multiply'; ctx.fillStyle = `rgba(${gain.r},${gain.g},${gain.b},${gain.m * .35})`; ctx.fillRect(0, 0, W, H); }
  ctx.globalCompositeOperation = 'source-over';
}
function renderTitles() {
  const layer = $('#title-layer');
  layer.innerHTML = state.titles.map(t => `
    <div class="title-card ${t.style}${state.t >= t.at && state.t < t.at + t.dur ? ' on' : ''}">
      <b>${esc(t.text)}</b>${t.style === 'lower' && t.sub ? `<span>${esc(t.sub)}</span>` : ''}
    </div>`).join('');
}
const esc = (s) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// MARK: Timeline

function renderTimeline() {
  const pps = state.pps, width = Math.max(total() + 8, 40) * pps;
  for (const id of ['ruler', 'v1', 'v2', 'a1']) $('#' + id).style.width = width + 'px';
  // Ruler: a tick a second, labels every 2.
  let r = '';
  for (let s = 0; s <= total() + 8; s++) {
    r += `<i class="${s % 2 ? '' : 'major'}" style="left:${s * pps}px"></i>`;
    if (s % 2 === 0) r += `<em style="left:${s * pps}px">${tc(s).slice(3, 8)}</em>`;
  }
  $('#ruler').innerHTML = r;
  // V1 clips with a filmstrip of their frame.
  const s = starts();
  $('#v1').innerHTML = state.clips.map((c, i) => `
    <div class="clip v${sel('clip', c.id) ? ' selected' : ''}" id="clip-${c.id}" data-clip="${c.id}" style="left:${s[i] * pps}px;width:${c.dur * pps - 2}px">
      <div class="name">${byId[c.id].name}</div>
      <div class="strip" style="background-image:url(/demo/img/supper-${c.id}.jpg)"></div>
      <div class="handle in" data-trim="in" aria-label="Trim start of ${byId[c.id].name}"></div>
      <div class="handle out" data-trim="out" aria-label="Trim end of ${byId[c.id].name}"></div>
    </div>`).join('');
  // V2 titles.
  $('#v2').innerHTML = state.titles.map(t => `
    <div class="clip t${sel('title', t.id) ? ' selected' : ''}${t.fresh ? ' fresh' : ''}" id="title-${t.id}" data-title="${t.id}" style="left:${t.at * pps}px;width:${t.dur * pps - 2}px">
      ${esc(t.text)}<small>${t.style === 'lower' ? 'Lower third' : 'Centre title'}</small>
      <div class="handle out" data-trim="out" aria-label="Trim end of title"></div>
    </div>`).join('');
  drawWave(width);
  placePlayhead();
}
const sel = (kind, id) => state.selected && state.selected.kind === kind && state.selected.id === id;
function drawWave(width) {
  const c = $('#wave'), x = c.getContext('2d'), H = 56;
  c.width = width; c.style.width = width + 'px';
  x.clearRect(0, 0, width, H);
  x.fillStyle = 'rgba(47,191,138,.16)'; x.fillRect(0, 6, total() * state.pps - 2, H - 12);
  x.strokeStyle = 'rgba(47,191,138,.55)'; x.strokeRect(.5, 6.5, total() * state.pps - 3, H - 13);
  x.fillStyle = '#3fd79f';
  let seed = 7;
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (let px = 2; px < total() * state.pps - 4; px += 3) {
    const sec = px / state.pps, beat = Math.pow(Math.abs(Math.sin(sec * Math.PI * 1.08)), 6);
    const a = (.18 + .5 * beat + .25 * rnd()) * (H - 18) / 2;
    x.fillRect(px, H / 2 - a, 2, a * 2);
  }
  x.fillStyle = 'rgba(255,255,255,.75)'; x.font = '600 10px -apple-system'; x.fillText('Sunday Table — score v3', 8, 18);
}
function placePlayhead() {
  $('#playhead').style.left = (state.t * state.pps) + 'px';
}

// Scrub on the ruler.
$('#ruler').addEventListener('pointerdown', (e) => {
  const scrub = (ev) => { const r = $('#tracks').getBoundingClientRect(); seek((ev.clientX - r.left + $('#tracks').scrollLeft) / state.pps); };
  scrub(e);
  const up = () => { removeEventListener('pointermove', scrub); removeEventListener('pointerup', up); };
  addEventListener('pointermove', scrub); addEventListener('pointerup', up);
});
function seek(t) { state.t = Math.max(0, Math.min(total(), t)); placePlayhead(); draw(); }

// Select, trim and move by hand.
$('#tracks').addEventListener('pointerdown', (e) => {
  const handle = e.target.closest('.handle'), el = e.target.closest('.clip');
  if (!el) return;
  const isTitle = el.classList.contains('t'), id = el.dataset.clip || el.dataset.title;
  select(isTitle ? 'title' : 'clip', id);
  const x0 = e.clientX, item = isTitle ? state.titles.find(t => t.id === id) : state.clips.find(c => c.id === id);
  const d0 = item.dur, a0 = item.at;
  const node = () => document.getElementById((isTitle ? 'title-' : 'clip-') + id);
  if (handle) {
    handle.classList.add('active');
    const side = handle.dataset.trim;
    const move = (ev) => {
      const dx = (ev.clientX - x0) / state.pps;
      if (isTitle) item.dur = Math.max(.5, d0 + dx);
      else item.dur = Math.max(1, Math.min(byId[id].len, d0 + (side === 'out' ? dx : -dx)));
      item.dur = Math.round(item.dur * FPS) / FPS;
      renderTimeline(); node().classList.add('dragging');
      tip(node(), side, item.dur - d0);
      draw();
    };
    const up = () => { removeEventListener('pointermove', move); removeEventListener('pointerup', up); renderTimeline(); changed(); };
    addEventListener('pointermove', move); addEventListener('pointerup', up);
  } else if (isTitle) {
    const move = (ev) => { item.at = Math.max(0, Math.round((a0 + (ev.clientX - x0) / state.pps) * FPS) / FPS); renderTimeline(); draw(); };
    const up = () => { removeEventListener('pointermove', move); removeEventListener('pointerup', up); changed(); };
    addEventListener('pointermove', move); addEventListener('pointerup', up);
  }
});
function tip(node, side, delta) {
  if (!node) return;
  const t = document.createElement('div');
  t.className = 'trim-tip';
  t.textContent = (delta >= 0 ? '+' : '−') + tc(Math.abs(delta)).slice(6);
  t.style.left = side === 'in' ? '0' : '100%';
  t.style.top = '18px';
  node.appendChild(t);
}
function select(kind, id) {
  state.selected = { kind, id };
  renderTimeline(); inspect();
  showTab(kind === 'title' ? 'title' : $('.tab.on').dataset.tab === 'color' ? 'color' : 'clip');
}

// MARK: Inspector

function showTab(name) {
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('on', b.dataset.tab === name));
  for (const n of ['clip', 'title', 'color']) $('#tab-' + n).hidden = n !== name;
  document.querySelectorAll('.page').forEach(b => b.classList.toggle('on', b.dataset.page === (name === 'color' ? 'color' : 'edit')));
}
document.querySelectorAll('.tab').forEach(b => b.onclick = () => showTab(b.dataset.tab));
document.querySelectorAll('.page').forEach(b => b.onclick = () => { if (b.dataset.page !== 'deliver') showTab(b.dataset.page === 'color' ? 'color' : 'clip'); else toast('Deliver is off in the demo.'); });

function inspect() {
  const s = state.selected;
  if (s && s.kind === 'clip') {
    const c = state.clips.find(c => c.id === s.id);
    $('#clip-name').textContent = byId[c.id].name; $('#clip-dur').textContent = tc(c.dur);
  }
  if (s && s.kind === 'title') {
    const t = state.titles.find(t => t.id === s.id);
    $('#title-text').value = t.text;
    document.querySelectorAll('#title-style button').forEach(b => b.classList.toggle('on', b.dataset.style === t.style));
  }
}
$('#clip-scale').oninput = (e) => { state.scale = +e.target.value; $('#clip-scale-v').textContent = state.scale + '%'; draw(); changed(); };
$('#title-text').oninput = (e) => {
  const s = state.selected; if (!s || s.kind !== 'title') return;
  state.titles.find(t => t.id === s.id).text = e.target.value; renderTimeline(); draw(); changed();
};
document.querySelectorAll('#title-style button').forEach(b => b.onclick = () => {
  const s = state.selected; if (!s || s.kind !== 'title') return;
  state.titles.find(t => t.id === s.id).style = b.dataset.style; inspect(); renderTimeline(); draw(); changed();
});
$('#add-title').onclick = () => api.addTitle($('#title-text').value || 'Sunday Table');

// Colour wheels: drag the puck; double-click resets.
const WHEELS = [['lift', 'Lift'], ['gamma', 'Gamma'], ['gain', 'Gain']];
$('#wheels').innerHTML = WHEELS.map(([k, label]) => `
  <div class="wheel"><div class="disc" id="wheel-${k}" data-wheel="${k}" aria-label="${label} colour wheel"><div class="puck"></div></div>
  <span><b>${label}</b><em class="mono" id="wheel-${k}-v">0.00</em></span></div>`).join('');
function placePucks() {
  for (const [k] of WHEELS) {
    const [x, y] = state.grade[k], p = document.querySelector(`#wheel-${k} .puck`);
    p.style.left = (50 + x * 38) + '%'; p.style.top = (50 + y * 38) + '%';
    $(`#wheel-${k}-v`).textContent = Math.hypot(x, y).toFixed(2);
  }
  $('#temp').value = state.grade.temp; $('#temp-v').textContent = Math.round(state.grade.temp);
  $('#sat').value = state.grade.sat; $('#sat-v').textContent = Math.round(state.grade.sat);
}
document.querySelectorAll('.disc').forEach(d => {
  d.addEventListener('pointerdown', (e) => {
    const k = d.dataset.wheel;
    const set = (ev) => {
      const r = d.getBoundingClientRect();
      let x = ((ev.clientX - r.left) / r.width - .5) / .38, y = ((ev.clientY - r.top) / r.height - .5) / .38;
      const m = Math.hypot(x, y); if (m > 1) { x /= m; y /= m; }
      state.grade[k] = [x, y]; placePucks(); draw();
    };
    set(e);
    const up = () => { removeEventListener('pointermove', set); removeEventListener('pointerup', up); changed(); };
    addEventListener('pointermove', set); addEventListener('pointerup', up);
  });
  d.addEventListener('dblclick', () => { state.grade[d.dataset.wheel] = [0, 0]; placePucks(); draw(); changed(); });
});
$('#temp').oninput = (e) => { state.grade.temp = +e.target.value; placePucks(); draw(); changed(); };
$('#sat').oninput = (e) => { state.grade.sat = +e.target.value; placePucks(); draw(); changed(); };
$('#reset-grade').onclick = () => { state.grade = { lift: [0, 0], gamma: [0, 0], gain: [0, 0], temp: 0, sat: 100 }; placePucks(); draw(); changed(); };

// MARK: Transport

let last = 0;
function loop(now) {
  if (!state.playing) return;
  state.t += (now - last) / 1000; last = now;
  if (state.t >= total()) { state.t = total(); pause(); }
  placePlayhead(); draw();
  requestAnimationFrame(loop);
}
function play() { if (state.t >= total()) state.t = 0; state.playing = true; last = performance.now(); $('#play').textContent = '❚❚'; requestAnimationFrame(loop); }
function pause() { state.playing = false; $('#play').textContent = '▶'; }
$('#play').onclick = () => state.playing ? pause() : play();
$('#to-start').onclick = () => seek(0);
$('#to-end').onclick = () => seek(total());
addEventListener('keydown', (e) => {
  if (e.target.matches('input')) return;
  if (e.code === 'Space') { e.preventDefault(); state.playing ? pause() : play(); }
  if (e.key === 'ArrowLeft') seek(state.t - 1 / FPS);
  if (e.key === 'ArrowRight') seek(state.t + 1 / FPS);
});
$('#zoom').oninput = (e) => { state.pps = +e.target.value; renderTimeline(); };

// MARK: Agent API: the same edits, eased so they read on camera.

const api = {
  state,
  /** Trim a clip's end (or start) by `delta` seconds, rippling the rest of the cut. */
  async trim(id, delta, { edge = 'out', ms = 900 } = {}) {
    const c = state.clips.find(c => c.id === id); if (!c) throw new Error('No clip ' + id);
    select('clip', id);
    const d0 = c.dur, d1 = Math.max(1, Math.min(byId[id].len, d0 + delta));
    await tween(ms, p => {
      c.dur = Math.round((d0 + (d1 - d0) * p) * FPS) / FPS;
      renderTimeline();
      const n = document.getElementById('clip-' + id);
      n.classList.add('dragging'); n.querySelector(`.handle.${edge}`).classList.add('active');
      tip(n, edge, c.dur - d0);
      draw();
    });
    renderTimeline(); inspect(); changed();
    return { id, duration: c.dur, total: total() };
  },
  /** Add a title on V2 at `at` seconds (default: the playhead). */
  async addTitle(text, { at = state.t, dur = 3, sub = '', style = 'lower' } = {}) {
    const t = { id: 't' + (state.titles.length + 1), at, dur, text, sub, style, fresh: true };
    state.titles.push(t);
    select('title', t.id);
    seek(at + .4);
    setTimeout(() => { t.fresh = false; }, 1300);
    changed();
    return t;
  },
  /** Ease a colour wheel to [x, y] (each -1…1; angle is hue, distance is strength). */
  async setWheel(name, x, y, { ms = 1100 } = {}) {
    showTab('color');
    const [x0, y0] = state.grade[name];
    await tween(ms, p => { state.grade[name] = [x0 + (x - x0) * p, y0 + (y - y0) * p]; placePucks(); draw(); });
    changed();
    return state.grade[name];
  },
  async setGrade({ temp, sat } = {}, { ms = 900 } = {}) {
    showTab('color');
    const t0 = state.grade.temp, s0 = state.grade.sat;
    await tween(ms, p => {
      if (temp !== undefined) state.grade.temp = t0 + (temp - t0) * p;
      if (sat !== undefined) state.grade.sat = s0 + (sat - s0) * p;
      placePucks(); draw();
    });
    changed();
    return state.grade;
  },
  seek, play, pause,
  /** Plain description of the cut, for an agent to read. */
  describe() {
    const s = starts();
    return {
      duration: tc(total()),
      clips: state.clips.map((c, i) => ({ id: c.id, name: byId[c.id].name, start: tc(s[i]), duration: +c.dur.toFixed(2) })),
      titles: state.titles.map(t => ({ text: t.text, at: tc(t.at), duration: t.dur })),
      grade: state.grade,
    };
  },
};
window.cutroom = api;

// Fit the whole cut in the timeline to start.
state.pps = Math.max(40, Math.min(160, Math.floor(($('#tracks').clientWidth - 40) / (total() + 3))));
$('#zoom').value = state.pps;
renderBins(); renderTimeline(); placePucks(); draw();
seek(5.2);
// Open on the long clip, the one the notes are about.
state.selected = { kind: 'clip', id: 'peach' }; renderTimeline(); inspect();
