// Browsa call audio: Browsa's own microphone processing for calls (Meet, Zoom, Teams and the like).
//
// WebKit hands echo cancellation, noise suppression and auto gain to Apple's voice processing unit,
// which on some audio interfaces lets echo through, boosts the mic far too much, or listens to the
// wrong input channel. Chrome runs its own processing instead. This script does the same inside the
// page: when a site asks for a processed mic, it opens the mic raw, runs it through Browsa's processor
// (an AudioWorklet), and hands the site the processed track. The call's incoming audio (remote
// WebRTC tracks) is the echo reference, which is what an echo canceller needs to know was played.
//
// Runs in the page world at document start, in every frame.
(() => {
  'use strict';
  if (window.__browsaCallAudio) return;
  const md = navigator.mediaDevices;
  if (!md || typeof md.getUserMedia !== 'function' || !window.AudioContext) return;

  const state = { version: 1, active: 0, references: 0, mode: 'starting', engine: 'loading', error: null };
  Object.defineProperty(window, '__browsaCallAudio', { value: state, enumerable: false });

  const RATE = 48000;
  let ctx = null, refBus = null, workletReady = null, trackCount = 0;

  function context() {
    if (!ctx) {
      ctx = new AudioContext({ sampleRate: RATE, latencyHint: 'interactive' });
      refBus = ctx.createGain();
    }
    if (ctx.state === 'suspended') ctx.resume().catch(() => {});
    return ctx;
  }

  // ---------- the processor ----------
  // Plain code so it runs in an AudioWorklet (from a blob URL) or, where a site's content security
  // policy blocks that, on the main thread in a ScriptProcessorNode.
  function makeVoice(options, post) {
    const FRAME = 480;                       // 10 ms at 48 kHz, the frame size WebRTC's processing uses
    const db = x => 10 * Math.log10(x + 1e-12);
    const v = {
      agcOn: options.autoGainControl !== false,
      mic: new Float32Array(FRAME), ref: new Float32Array(FRAME), fill: 0,
      out: new Float32Array(FRAME * 8), outRead: 0, outWrite: 0, outCount: 0,
      gainDb: 0, noiseDb: -70, speechDb: -30, peakEnv: 0, frames: 0, farHold: 0, stopped: false,
      engine: null,                          // an echo canceller plugs in here
    };

    // One 10 ms frame: mic and reference in, processed mic out (in place).
    function frame(mic, ref) {
      let refPow = 0; for (let i = 0; i < FRAME; i++) refPow += ref[i] * ref[i];
      refPow /= FRAME;
      if (v.engine && !v.engine.process(mic, ref)) v.engine = null;   // on any failure, carry on without it
      let pow = 0; for (let i = 0; i < FRAME; i++) pow += mic[i] * mic[i];
      const lvl = db(pow / FRAME);
      // Noise floor: falls fast, rises slowly. Exact-zero frames (a device still starting) don't count.
      if (lvl > -100) v.noiseDb = lvl < v.noiseDb ? 0.7 * v.noiseDb + 0.3 * lvl : v.noiseDb + 0.02;
      // While the call's audio is playing, and for 300 ms after (the room's echo tail), what the mic
      // hears may be the speakers, so the gain doesn't learn from it.
      if (refPow > 1e-6) v.farHold = 30; else if (v.farHold > 0) v.farHold--;
      const speaking = v.farHold === 0 && lvl > v.noiseDb + 9 && lvl > -65;
      if (v.agcOn && !(v.engine && v.engine.gain)) {
        if (speaking) v.speechDb = 0.97 * v.speechDb + 0.03 * lvl;
        // Aim speech at -23 dBFS like WebRTC's gain controller, within -18 to +12 dB.
        const target = Math.max(-18, Math.min(12, -23 - v.speechDb));
        // Gain only rises from the user's own speech; it can always come down.
        const step = target > v.gainDb ? (speaking ? 0.015 : 0) : 0.25;   // dB per frame: ~1.5 dB/s up, fast down
        v.gainDb += Math.max(-step, Math.min(step, target - v.gainDb));
      } else {
        v.gainDb += (0 - v.gainDb) * 0.1;
      }
      const g = 10 ** (v.gainDb / 20);
      for (let i = 0; i < FRAME; i++) {
        let x = mic[i] * g;
        const a = Math.abs(x);
        v.peakEnv = a > v.peakEnv ? a : v.peakEnv * 0.9995;
        if (v.peakEnv > 0.89) x *= 0.89 / v.peakEnv;   // soft limit at about -1 dBFS
        mic[i] = x;
      }
      if (++v.frames % 100 === 0) post({ type: 'stats', levelDb: lvl, gainDb: v.gainDb, noiseDb: v.noiseDb, refDb: db(refPow), engine: !!v.engine });
    }

    // Any block size in and out. Averages every channel the device gives, so a mic on input 2 of an
    // interface still counts.
    v.block = (micIn, refIn, out) => {
      const n = out.length;
      for (let i = 0; i < n; i++) {
        let m = 0;
        if (micIn && micIn.length) { for (let c = 0; c < micIn.length; c++) m += micIn[c][i]; m /= micIn.length; }
        let r = 0;
        if (refIn && refIn.length) { for (let c = 0; c < refIn.length; c++) r += refIn[c][i]; r /= refIn.length; }
        v.mic[v.fill] = m; v.ref[v.fill] = r;
        if (++v.fill === FRAME) {
          frame(v.mic, v.ref);
          for (let k = 0; k < FRAME; k++) { v.out[v.outWrite] = v.mic[k]; v.outWrite = (v.outWrite + 1) % v.out.length; }
          v.outCount = Math.min(v.out.length, v.outCount + FRAME); v.fill = 0;
        }
      }
      for (let i = 0; i < n; i++) {
        if (v.outCount > 0) { out[i] = v.out[v.outRead]; v.outRead = (v.outRead + 1) % v.out.length; v.outCount--; }
        else out[i] = 0;
      }
    };
    v.settings = m => {
      if ('autoGainControl' in m) v.agcOn = m.autoGainControl;
      if (m.stop) { v.stopped = true; if (v.engine) v.engine.destroy(); v.engine = null; }
      if (m.flags !== undefined && v.engine) v.engine.configure(m.flags);
    };
    // WebRTC's audio processing (echo canceller, noise suppressor, gain controller) as WebAssembly.
    v.loadEngine = (bytes, flags) => {
      try { v.engine = makeApm(bytes, flags); }
      catch (e) { post({ type: 'engine-error', message: String(e && e.message || e) }); }
      post({ type: 'engine', ok: !!v.engine });
    };

    function makeApm(bytes, flags) {
      let memory = null;
      const view = () => new DataView(memory.buffer);
      // Standalone WebAssembly from Emscripten asks for a few WASI calls; none of them need the outside world.
      const wasi = {
        fd_write(fd, iovs, count, written) {
          let total = 0; const d = view();
          for (let i = 0; i < count; i++) total += d.getUint32(iovs + i * 8 + 4, true);
          d.setUint32(written, total, true); return 0;
        },
        clock_time_get(id, precision, out) { view().setBigUint64(out, BigInt(Math.round(Date.now() * 1e6)), true); return 0; },
        random_get(buf, len) { const u = new Uint8Array(memory.buffer, buf, len); for (let i = 0; i < len; i++) u[i] = (Math.random() * 256) | 0; return 0; },
        environ_sizes_get(a, b) { const d = view(); d.setUint32(a, 0, true); d.setUint32(b, 0, true); return 0; },
        args_sizes_get(a, b) { const d = view(); d.setUint32(a, 0, true); d.setUint32(b, 0, true); return 0; },
        proc_exit(code) { throw new Error('webrtc exited ' + code); },
      };
      const anyCall = table => new Proxy(table, { get: (t, k) => (k in t ? t[k] : () => 0) });
      const imports = new Proxy({}, { get: (_, mod) => anyCall(mod === 'wasi_snapshot_preview1' ? wasi : {}) });
      const module = new WebAssembly.Module(bytes);
      const want = {};
      for (const imp of WebAssembly.Module.imports(module)) (want[imp.module] = want[imp.module] || {})[imp.name] = imports[imp.module][imp.name];
      const inst = new WebAssembly.Instance(module, want);
      const x = inst.exports;
      memory = x.memory;
      if (x._initialize) x._initialize();
      const h = x.apm_create(flags);
      if (!h) throw new Error('apm_create failed');
      const micPtr = x.apm_mic(h), refPtr = x.apm_ref(h);
      return {
        gain: (flags & 4) !== 0,
        configure(f) { x.apm_configure(h, f); this.gain = (f & 4) !== 0; },
        process(mic, ref) {
          const heap = new Float32Array(memory.buffer);
          heap.set(mic, micPtr >> 2); heap.set(ref, refPtr >> 2);
          if (x.apm_process(h, 0) !== 0) return false;
          mic.set(new Float32Array(memory.buffer, micPtr, mic.length));
          return true;
        },
        destroy() { try { x.apm_destroy(h); } catch {} },
      };
    }
    return v;
  }

  const WORKLET = `const makeVoice = ${makeVoice.toString()};
  registerProcessor('browsa-voice', class extends AudioWorkletProcessor {
    constructor(o) {
      super();
      this.v = makeVoice(o.processorOptions || {}, m => this.port.postMessage(m));
      this.port.onmessage = e => {
        const m = e.data || {};
        if (m.type === 'settings') this.v.settings(m);
        if (m.type === 'engine') this.v.loadEngine(m.bytes, m.flags);
      };
    }
    process(inputs, outputs) { if (this.v.stopped) return false; this.v.block(inputs[0], inputs[1], outputs[0][0]); return true; }
  });`;

  function ensureWorklet() {
    if (!workletReady) {
      const url = URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' }));
      workletReady = context().audioWorklet.addModule(url).then(() => true, e => { state.error = 'worklet: ' + e.message; return false; })
        .finally(() => URL.revokeObjectURL(url));
    }
    return workletReady;
  }

  // The processor as a node: [node, mic input index, ref input index, send settings].
  async function voiceNode(c, options, onStats) {
    if (window.AudioWorkletNode && await ensureWorklet()) {
      const node = new AudioWorkletNode(c, 'browsa-voice', { numberOfInputs: 2, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: options });
      node.port.onmessage = e => onStats(e.data);
      return { mic: node, ref: node, refInput: 1, out: node, settings: m => node.port.postMessage({ type: 'settings', ...m }),
               engine: (bytes, flags) => node.port.postMessage({ type: 'engine', bytes: bytes.slice(0), flags }), kind: 'worklet' };
    }
    // Main-thread fallback: one ScriptProcessor with mic on the left channel and reference on the right.
    const merge = c.createChannelMerger(2);
    const sp = c.createScriptProcessor(512, 2, 1);
    const v = makeVoice(options, onStats);
    sp.onaudioprocess = e => {
      const ib = e.inputBuffer;
      v.block([ib.getChannelData(0)], [ib.getChannelData(1)], e.outputBuffer.getChannelData(0));
    };
    merge.connect(sp);
    // ScriptProcessors only run while connected to the destination; send it there silenced.
    const mute = c.createGain(); mute.gain.value = 0; sp.connect(mute); mute.connect(c.destination);
    return { mic: merge, micInput: 0, ref: merge, refInput: 1, out: sp, settings: m => v.settings(m),
             engine: (bytes, flags) => v.loadEngine(bytes, flags), kind: 'main-thread' };
  }

  // ---------- WebRTC's audio processing, fetched from Browsa once per page ----------
  let apmBytes = null;
  function loadApm() {
    if (!apmBytes) {
      apmBytes = (async () => {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browsaCallAudio;
        if (h) {
          const b64 = await h.postMessage({ type: 'apm' });
          if (!b64) return null;
          const bin = atob(b64), u = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
          return u;
        }
        // Outside Browsa (the test page in another browser, or tests): a URL set before the page's scripts run.
        if (window.__browsaCallAudioApmURL) return new Uint8Array(await (await fetch(window.__browsaCallAudioApmURL)).arrayBuffer());
        return null;
      })().catch(e => { state.error = 'apm: ' + e.message; return null; });
    }
    return apmBytes;
  }
  const flagsFor = asked => (asked.echoCancellation ? 1 : 0) | (asked.noiseSuppression ? 2 : 0) | (asked.autoGainControl ? 4 : 0);

  // ---------- echo reference: the call's incoming audio ----------
  function addReference(track) {
    if (!track || track.kind !== 'audio') return;
    try {
      const src = context().createMediaStreamSource(new MediaStream([track]));
      src.connect(refBus);
      state.references++;
      track.addEventListener('ended', () => { try { src.disconnect(); } catch {} state.references--; }, { once: true });
    } catch (e) { state.error = 'reference: ' + e.message; }
  }

  const NativePC = window.RTCPeerConnection;
  if (NativePC) {
    const Wrapped = function RTCPeerConnection(...args) {
      const pc = new NativePC(...args);
      pc.addEventListener('track', e => addReference(e.track));
      return pc;
    };
    Wrapped.prototype = NativePC.prototype;
    Object.setPrototypeOf(Wrapped, NativePC);
    try { Object.defineProperty(Wrapped, 'name', { value: 'RTCPeerConnection' }); } catch {}
    window.RTCPeerConnection = Wrapped;
    if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = Wrapped;
  }

  // ---------- getUserMedia ----------
  const PROCESSING = ['echoCancellation', 'noiseSuppression', 'autoGainControl'];
  // A constraint counts as on unless the site turned it off (WebKit's default is on).
  function wants(audio, key) {
    if (audio === true || audio == null) return true;
    const v = audio[key];
    if (v === undefined) return true;
    if (typeof v === 'object' && v !== null) return (v.exact ?? v.ideal ?? true) !== false;
    return v !== false;
  }

  async function processTrack(raw, asked) {
    const c = context();
    const src = c.createMediaStreamSource(new MediaStream([raw]));
    const id = ++trackCount;
    const voice = await voiceNode(c, { autoGainControl: asked.autoGainControl }, m => {
      if (!m || id !== trackCount) return;
      if (m.type === 'stats') state.last = m;
      if (m.type === 'engine') state.engine = m.ok ? 'webrtc' : 'none';
      if (m.type === 'engine-error') state.error = 'engine: ' + m.message;
    });
    loadApm().then(bytes => { if (bytes) voice.engine(bytes, flagsFor(asked)); else state.engine = 'none'; });
    const dest = c.createMediaStreamDestination();
    dest.channelCount = 1;
    if (voice.kind === 'worklet') { src.connect(voice.mic, 0, 0); refBus.connect(voice.ref, 0, 1); }
    else {
      // Downmix the mic to one channel first so it fits the merger's left input.
      const down = c.createGain(); down.channelCount = 1; down.channelCountMode = 'explicit'; down.channelInterpretation = 'speakers';
      src.connect(down); down.connect(voice.mic, 0, 0);
      const refDown = c.createGain(); refDown.channelCount = 1; refDown.channelCountMode = 'explicit';
      refBus.connect(refDown); refDown.connect(voice.ref, 0, 1);
      voice.refTap = refDown;
    }
    voice.out.connect(dest);
    state.processor = voice.kind;
    const track = dest.stream.getAudioTracks()[0];
    state.active++;

    // Look like the device the site picked, with the processing it asked for.
    const settings = () => ({ ...raw.getSettings(), ...asked, channelCount: 1, sampleRate: RATE });
    Object.defineProperties(track, {
      label: { get: () => raw.label },
      getSettings: { value: settings },
      getCapabilities: { value: () => raw.getCapabilities ? raw.getCapabilities() : {} },
      getConstraints: { value: () => raw.getConstraints() },
      applyConstraints: { value: async (cons = {}) => {
        const rest = { ...cons };
        for (const k of PROCESSING) { if (k in rest) { asked[k] = wants(rest, k); delete rest[k]; } }
        voice.settings({ autoGainControl: asked.autoGainControl, flags: flagsFor(asked) });
        return raw.applyConstraints(rest);
      } },
    });
    let stopped = false;
    const cleanup = () => {
      if (stopped) return; stopped = true;
      raw.stop();
      voice.settings({ stop: true });
      for (const n of [src, voice.out, voice.refTap]) { try { n && n.disconnect(); } catch {} }
      if (voice.kind === 'worklet') { try { refBus.disconnect(voice.ref); } catch {} }
      state.active--;
    };
    const nativeStop = track.stop.bind(track);
    Object.defineProperty(track, 'stop', { value: () => { nativeStop(); cleanup(); } });
    raw.addEventListener('ended', () => { nativeStop(); cleanup(); track.dispatchEvent(new Event('ended')); }, { once: true });
    // Muting by `enabled` on the processed track already sends silence; mirror it so the device light follows.
    return track;
  }

  const nativeGUM = md.getUserMedia.bind(md);
  md.getUserMedia = async function getUserMedia(constraints) {
    const audio = constraints && constraints.audio;
    if (!audio) return nativeGUM(constraints);
    const asked = Object.fromEntries(PROCESSING.map(k => [k, wants(audio, k)]));
    // Browsa only takes over when the site wants processing. Raw requests (music sites) pass straight through.
    if (!asked.echoCancellation && !asked.noiseSuppression && !asked.autoGainControl) return nativeGUM(constraints);
    const rawAudio = typeof audio === 'object' ? { ...audio } : {};
    for (const k of PROCESSING) rawAudio[k] = false;
    if (Array.isArray(rawAudio.advanced)) rawAudio.advanced = rawAudio.advanced.filter(a => !Object.keys(a).some(k => /^goog|^echo|^noise|^autoGain/.test(k)));
    const stream = await nativeGUM({ ...constraints, audio: rawAudio });
    const raw = stream.getAudioTracks()[0];
    if (!raw) return stream;
    try {
      const processed = await processTrack(raw, asked);
      stream.removeTrack(raw);
      stream.addTrack(processed);
      state.mode = 'browsa';
    } catch (e) {
      // Fall back to WebKit's own processing rather than fail the call.
      state.mode = 'webkit'; state.error = e.message;
      raw.stop();
      return nativeGUM(constraints);
    }
    return stream;
  };

  // Old callback form some sites still use.
  if (navigator.webkitGetUserMedia) {
    navigator.webkitGetUserMedia = (c, ok, fail) => md.getUserMedia(c).then(ok, fail);
  }
})();
