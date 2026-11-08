// Browsa debug builds, with BROWSA_EXT_DIAGNOSTICS: an extension background's lifecycle in Browsa's log.
// Message names and senders only, never contents (they can carry account data).
// In the extension's own pages (popup, options) it logs errors, console errors and failed messages.
(() => {
  if (typeof window !== 'undefined' && !globalThis.__browsaDiagnostics) {
    globalThis.__browsaDiagnostics = true;
    const who = (() => { try { return chrome.runtime.getManifest().name.replace(/__MSG_(\w+)__/, (m, k) => chrome.i18n.getMessage(k) || chrome.runtime.id).slice(0, 30); } catch (e) { return '?'; } })();
    const page = location.pathname;
    const say = (l) => { try { const r = chrome.runtime.sendNativeMessage('browsa.log', { line: 'PG[' + who + '] ' + page + ' ' + l }); if (r && r.catch) r.catch(() => {}); } catch (e) {} };
    say('loaded');
    addEventListener('error', e => say('error ' + e.message + ' @' + String(e.filename || '').split('/').pop() + ':' + e.lineno));
    addEventListener('unhandledrejection', e => say('rejection ' + String(e.reason && (e.reason.stack || e.reason.message || e.reason)).slice(0, 300)));
    for (const level of ['error', 'warn']) {
      const original = console[level].bind(console);
      console[level] = (...a) => { say(level + ': ' + a.map(x => { try { return typeof x === 'string' ? x : (x && (x.stack || x.message)) || JSON.stringify(x); } catch (e) { return String(x); } }).join(' ').slice(0, 300)); original(...a); };
    }
    return;
  }
  if (typeof window !== 'undefined' || globalThis.__browsaDiagnostics) return;
  globalThis.__browsaDiagnostics = true;
  const t0 = Date.now();
  const who = (() => { try { return chrome.runtime.getManifest().name.replace(/__MSG_(\w+)__/, (m, k) => chrome.i18n.getMessage(k) || chrome.runtime.id).slice(0, 30); } catch (e) { return '?'; } })();
  const say = (l) => { try { const r = chrome.runtime.sendNativeMessage('browsa.log', { line: 'BG[' + who + '] ' + l }); if (r && r.catch) r.catch(() => {}); } catch (e) {} };
  say('started; filled in: ' + (globalThis.__browsaCompatMissing || []).join(' '));
  let last = Date.now();
  setInterval(() => {
    const now = Date.now();
    // The interval is 10 s; a much longer gap means this background's process was paused.
    if (now - last > 20000) say('PAUSED for ' + Math.round((now - last) / 1000 - 10) + 's (resumed now)');
    last = now;
    say('alive ' + Math.round((now - t0) / 1000) + 's');
  }, 10000);
  self.addEventListener('error', e => say('error ' + e.message + ' @' + String(e.filename || '').split('/').pop() + ':' + e.lineno));
  self.addEventListener('unhandledrejection', e => say('rejection ' + String(e.reason && (e.reason.message || e.reason)).slice(0, 200)));
  chrome.runtime.onConnect.addListener(p => {
    say('port ' + String(p.name).slice(0, 40) + ' from ' + String((p.sender && p.sender.url) || '').replace(/[?#].*/, '').slice(0, 70));
  });
  chrome.runtime.onMessage.addListener((m, sender) => {
    say('message ' + String(m && (m.name || m.type) || typeof m).slice(0, 50) + ' from ' + String((sender && sender.url) || '').replace(/[?#].*/, '').slice(0, 70));
    return false;
  });
  const NativeWS = globalThis.WebSocket;
  if (NativeWS && NativeWS.name === 'BrowsaWebSocket') {
    globalThis.WebSocket = class extends NativeWS {
      constructor(url, p) {
        super(url, p);
        const host = (() => { try { return new URL(url).host; } catch (e) { return '?'; } })();
        say('websocket to ' + host);
        this.addEventListener('open', () => say('websocket open ' + host));
        this.addEventListener('close', e => say('websocket closed ' + host + ' ' + e.code));
      }
    };
  }
  for (const level of ['error', 'warn']) {
    const original = console[level].bind(console);
    console[level] = (...a) => { say(level + ': ' + a.map(x => { try { return typeof x === 'string' ? x : (x && x.message) || JSON.stringify(x); } catch (e) { return String(x); } }).join(' ').slice(0, 240)); original(...a); };
  }
})();
