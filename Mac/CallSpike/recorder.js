// Call spike recorder: what this side sends (the mic track Chromium hands the page, after its echo
// cancelling) and what it receives (every remote audio track), as 20 ms levels plus 16 kHz audio.
(() => {
  if (window.__echoRec || window.top !== window) return;
  const R = window.__echoRec = { remote: [], local: null, ctx: null, lv: [], pcm: [[], []], add: null, t0: Date.now() };
  const NPC = window.RTCPeerConnection;
  if (NPC) {
    const PC = function RTCPeerConnection(...a) {
      const pc = new NPC(...a);
      pc.addEventListener('track', e => { if (e.track.kind === 'audio') { R.remote.push(e.track); if (R.add) R.add(e.track); } });
      return pc;
    };
    PC.prototype = NPC.prototype; Object.setPrototypeOf(PC, NPC); window.RTCPeerConnection = PC;
  }
  // Meet plays the other people through media elements; catch their tracks there too, in case the
  // peer connection was made before this script ran.
  const so = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
  Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', { ...so, set(v) {
    so.set.call(this, v);
    try { if (v && v.getAudioTracks) for (const t of v.getAudioTracks()) if (t !== R.local && !R.remote.includes(t)) { R.remote.push(t); if (R.add) R.add(t); } } catch {}
  } });
  // Elements that already have a stream when this runs.
  for (const el of document.querySelectorAll('audio,video')) { try { const v = so.get.call(el); if (v && v.getAudioTracks) for (const t of v.getAudioTracks()) if (!R.remote.includes(t)) R.remote.push(t); } catch {} }
  // The mic track the call sends, caught where it's handed to the peer connection (the page may have kept
  // its own reference to getUserMedia from before this script ran).
  const useLocal = t => { if (t && t.kind === 'audio' && t !== R.local) { R.local = t; R.settings = t.getSettings(); R.start(); } };
  const P = window.RTCPeerConnection && RTCPeerConnection.prototype;
  if (P) {
    const at = P.addTrack; P.addTrack = function (t, ...s) { try { useLocal(t); } catch {} return at.call(this, t, ...s); };
    const ax = P.addTransceiver; P.addTransceiver = function (t, ...s) { try { if (t && t.kind) useLocal(t); } catch {} return ax.call(this, t, ...s); };
  }
  if (window.RTCRtpSender) {
    const rt = RTCRtpSender.prototype.replaceTrack;
    RTCRtpSender.prototype.replaceTrack = function (t) { try { useLocal(t); } catch {} return rt.call(this, t); };
  }
  const md = navigator.mediaDevices, gum = md.getUserMedia.bind(md);
  md.getUserMedia = async c => {
    const s = await gum(c);
    const t = s.getAudioTracks()[0];
    if (t) useLocal(t);
    return s;
  };
  R.start = () => {
    if (R.ctx) R.ctx.close();
    const ctx = R.ctx = new AudioContext({ sampleRate: 48000 });
    const merge = ctx.createChannelMerger(2), remoteBus = ctx.createGain();
    remoteBus.connect(merge, 0, 1);
    ctx.createMediaStreamSource(new MediaStream([R.local])).connect(merge, 0, 0);
    const seen = new Set();
    R.add = t => {
      if (seen.has(t.id) || t.readyState === 'ended') return;
      seen.add(t.id);
      const ms = new MediaStream([t]);
      ctx.createMediaStreamSource(ms).connect(remoteBus);
    };
    R.remote.forEach(R.add);
    const sp = ctx.createScriptProcessor(1024, 2, 1);
    const acc = [0, 0]; let n = 0; const dec = [0, 0]; let dn = 0;
    sp.onaudioprocess = e => {
      const a = e.inputBuffer.getChannelData(0), b = e.inputBuffer.getChannelData(1);
      for (let i = 0; i < a.length; i++) {
        acc[0] += a[i] * a[i]; acc[1] += b[i] * b[i];
        dec[0] += a[i]; dec[1] += b[i];
        if (++dn === 3) { R.pcm[0].push(Math.max(-32768, Math.min(32767, dec[0] / 3 * 32767 | 0))); R.pcm[1].push(Math.max(-32768, Math.min(32767, dec[1] / 3 * 32767 | 0))); dec[0] = dec[1] = 0; dn = 0; }
        if (++n === 960) { R.lv.push([+(10 * Math.log10(acc[0] / 960 + 1e-15)).toFixed(1), +(10 * Math.log10(acc[1] / 960 + 1e-15)).toFixed(1)]); acc[0] = acc[1] = 0; n = 0; }
      }
    };
    merge.connect(sp);
    const mute = ctx.createGain(); mute.gain.value = 0; sp.connect(mute); mute.connect(ctx.destination);
    ctx.resume();
  };
  const b64 = arr => { const u = new Uint8Array(new Int16Array(arr).buffer); let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
  R.take = () => {
    const out = { t: Date.now(), hidden: document.hidden, ctx: R.ctx && R.ctx.state, remoteTracks: R.remote.filter(t => t.readyState === 'live').length,
                  settings: R.settings || null, lv: R.lv, sent: b64(R.pcm[0]), got: b64(R.pcm[1]) };
    R.lv = []; R.pcm = [[], []];
    return out;
  };
})();
