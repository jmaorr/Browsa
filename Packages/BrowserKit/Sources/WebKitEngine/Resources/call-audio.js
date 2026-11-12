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

  const state = { version: 1, active: 0, references: 0, mode: 'starting', error: null };
  Object.defineProperty(window, '__browsaCallAudio', { value: state, enumerable: false });

  const RATE = 48000;
  let ctx = null, refBus = null, workletReady = null;

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
      gainDb: 0, noiseDb: -70, speechDb: -30, peakEnv: 0, frames: 0,
      engine: null,                          // an echo canceller plugs in here
    };

    // One 10 ms frame: mic and reference in, processed mic out (in place).
    function frame(mic, ref) {
      let refPow = 0; for (let i = 0; i < FRAME; i++) refPow += ref[i] * ref[i];
      refPow /= FRAME;
      if (v.engine) v.engine.process(mic, ref);
      let pow = 0; for (let i = 0; i < FRAME; i++) pow += mic[i] * mic[i];
      const lvl = db(pow / FRAME);
      // Noise floor: falls fast, rises slowly.
      v.noiseDb = lvl < v.noiseDb ? 0.7 * v.noiseDb + 0.3 * lvl : v.noiseDb + 0.02;
      const speaking = lvl > v.noiseDb + 9 && lvl > -65;
      if (v.agcOn) {
        if (speaking) v.speechDb = 0.97 * v.speechDb + 0.03 * lvl;
        // Aim speech at -23 dBFS like WebRTC's gain controller, within ±18 dB.
        const target = Math.max(-18, Math.min(18, -23 - v.speechDb));
        // Don't chase gain up while only the far end is talking: that's echo, not the user.
        const farOnly = refPow > 1e-6 && !speaking;
        const step = target > v.gainDb ? (farOnly ? 0 : 0.015) : 0.25;   // dB per frame: ~1.5 dB/s up, fast down
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
    v.settings = m => { if ('autoGainControl' in m) v.agcOn = m.autoGainControl; };
    return v;
  }

  const WORKLET = `const makeVoice = ${makeVoice.toString()};
  registerProcessor('browsa-voice', class extends AudioWorkletProcessor {
    constructor(o) {
      super();
      this.v = makeVoice(o.processorOptions || {}, m => this.port.postMessage(m));
      this.port.onmessage = e => e.data && e.data.type === 'settings' && this.v.settings(e.data);
    }
    process(inputs, outputs) { this.v.block(inputs[0], inputs[1], outputs[0][0]); return true; }
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
      return { mic: node, ref: node, refInput: 1, out: node, settings: m => node.port.postMessage({ type: 'settings', ...m }), kind: 'worklet' };
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
    return { mic: merge, micInput: 0, ref: merge, refInput: 1, out: sp, settings: m => v.settings(m), kind: 'main-thread' };
  }

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
    const voice = await voiceNode(c, { autoGainControl: asked.autoGainControl }, m => { if (m && m.type === 'stats') state.last = m; });
    const dest = c.createMediaStreamDestination();
    dest.channelCount = 1;
    if (voice.kind === 'worklet') { src.connect(voice.mic, 0, 0); refBus.connect(voice.ref, 0, 1); }
    else {
      // Downmix the mic to one channel first so it fits the merger's left input.
      const down = c.createGain(); down.channelCount = 1; down.channelCountMode = 'explicit'; down.channelInterpretation = 'speakers';
      src.connect(down); down.connect(voice.mic, 0, 0);
      const refDown = c.createGain(); refDown.channelCount = 1; refDown.channelCountMode = 'explicit';
      refBus.connect(refDown); refDown.connect(voice.ref, 0, 1);
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
        voice.settings({ autoGainControl: asked.autoGainControl });
        return raw.applyConstraints(rest);
      } },
    });
    let stopped = false;
    const cleanup = () => {
      if (stopped) return; stopped = true;
      raw.stop();
      try { src.disconnect(); voice.out.disconnect(); } catch {}
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
