// Browsa: runs in an extension's background before the extension's own code. It fills in what
// WebKit's extension runtime lacks for extensions built for Chrome, and works around two WebKit
// problems in service workers. Plain objects only: wrapping WebKit's API objects in a Proxy breaks
// message delivery.
(() => {
  if (globalThis.__browsaCompat) return;
  globalThis.__browsaCompat = true;
  const isWorker = typeof window === 'undefined';
  const roots = [globalThis.chrome, globalThis.browser].filter((r, i, all) => r && all.indexOf(r) === i);
  // WebKit may drop a namespace's JS wrapper (and anything added to it) and hand out a fresh one, so
  // keep a reference to every object patched here.
  const kept = [];
  const keep = (o) => { kept.push(o); return o; };
  globalThis.__browsaCompatKept = kept;

  const event = () => {
    const listeners = new Set();
    return {
      addListener(fn) { listeners.add(fn); },
      removeListener(fn) { listeners.delete(fn); },
      hasListener(fn) { return listeners.has(fn); },
      hasListeners() { return listeners.size > 0; },
    };
  };
  const unsupported = (name) => () => Promise.reject(new Error(`${name} isn't supported in Browsa`));
  const resolves = (value) => () => Promise.resolve(value);

  // Namespaces WebKit doesn't have. Events never fire; calls either answer the way a browser with
  // nothing to report would, or reject.
  const namespaces = {
    notifications: () => ({
      create: resolves(''), update: resolves(false), clear: resolves(false), getAll: resolves({}),
      getPermissionLevel: resolves('denied'),
      onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event(), onPermissionLevelChanged: event(),
    }),
    idle: () => ({
      queryState: resolves('active'), setDetectionInterval() {}, getAutoLockDelay: resolves(0),
      onStateChanged: event(),
    }),
    management: () => ({
      getSelf: () => Promise.resolve({ id: chrome.runtime.id, name: chrome.runtime.getManifest().name, enabled: true, installType: 'normal', type: 'extension', version: chrome.runtime.getManifest().version }),
      getAll: resolves([]), get: unsupported('management.get'),
      onInstalled: event(), onUninstalled: event(), onEnabled: event(), onDisabled: event(),
    }),
    privacy: () => {
      const setting = () => ({ get: resolves({ value: false, levelOfControl: 'not_controllable' }), set: resolves(undefined), clear: resolves(undefined), onChange: event() });
      return { services: { passwordSavingEnabled: setting(), autofillAddressEnabled: setting(), autofillCreditCardEnabled: setting(), autofillEnabled: setting() }, network: {}, websites: {} };
    },
    downloads: () => ({
      download: unsupported('downloads.download'), search: resolves([]), open: unsupported('downloads.open'),
      onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event(),
    }),
    offscreen: () => ({ createDocument: unsupported('offscreen'), closeDocument: resolves(undefined), hasDocument: resolves(false) }),
    sidePanel: () => ({ setOptions: resolves(undefined), setPanelBehavior: resolves(undefined), open: unsupported('sidePanel.open'), getOptions: resolves({}) }),
    identity: () => ({ launchWebAuthFlow: unsupported('identity.launchWebAuthFlow'), getRedirectURL: (p = '') => `https://${chrome.runtime.id}.chromiumapp.org/${p}`, onSignInChanged: event() }),
    contentSettings: () => ({}),
  };
  // Events missing from namespaces WebKit does have.
  const events = {
    runtime: ['onStartup', 'onInstalled', 'onSuspend', 'onSuspendCanceled', 'onUpdateAvailable', 'onConnectExternal', 'onMessageExternal', 'onRestartRequired'],
    tabs: ['onCreated', 'onRemoved', 'onUpdated', 'onActivated', 'onReplaced', 'onHighlighted', 'onMoved', 'onAttached', 'onDetached', 'onZoomChange'],
    windows: ['onCreated', 'onRemoved', 'onFocusChanged', 'onBoundsChanged'],
    webNavigation: ['onCreatedNavigationTarget', 'onBeforeNavigate', 'onCommitted', 'onCompleted', 'onDOMContentLoaded', 'onErrorOccurred', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onTabReplaced'],
    webRequest: ['onAuthRequired', 'onBeforeRedirect', 'onBeforeRequest', 'onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived', 'onResponseStarted', 'onCompleted', 'onErrorOccurred'],
    action: ['onClicked', 'onUserSettingsChanged'],
    contextMenus: ['onClicked'],
    alarms: ['onAlarm'],
    permissions: ['onAdded', 'onRemoved'],
    commands: ['onCommand'],
  };
  const missing = [];
  for (const root of roots) {
    for (const [name, make] of Object.entries(namespaces)) {
      if (root[name] === undefined) {
        try { root[name] = keep(make()); missing.push(name); } catch (e) {}
      }
    }
    for (const [ns, names] of Object.entries(events)) {
      const target = root[ns];
      if (!target) continue;
      keep(target);
      for (const name of names) {
        if (target[name] === undefined) {
          try { target[name] = event(); missing.push(`${ns}.${name}`); } catch (e) {}
        }
      }
    }
    if (root.storage && root.storage.managed === undefined) {
      try {
        keep(root.storage).managed = { get: resolves({}), getBytesInUse: resolves(0), onChanged: event() };
        missing.push('storage.managed');
      } catch (e) {}
    }
  }
  globalThis.__browsaCompatMissing = missing;

  if (!isWorker) return;

  // navigator.locks, inside the worker. WebKit's own goes over IPC to a lock registry that can reject
  // a service worker's requests ("Received an invalid message") and leave them pending for ever.
  // Locks only need to coordinate this extension's own code, so a local implementation is enough.
  const lockQueues = new Map();   // name -> [{ mode, grant, signal, held }]
  const held = new Map();         // name -> [{ mode, clientId }]
  const tryGrant = (name) => {
    const queue = lockQueues.get(name) || [];
    let current = held.get(name) || [];
    while (queue.length) {
      const next = queue[0];
      const compatible = current.length === 0 || (next.mode === 'shared' && current.every(h => h.mode === 'shared'));
      if (!compatible) break;
      queue.shift();
      const entry = { mode: next.mode };
      current = [...current, entry];
      held.set(name, current);
      next.grant(entry);
      if (next.mode === 'exclusive') break;
    }
    if (!queue.length) lockQueues.delete(name);
  };
  const release = (name, entry) => {
    const list = (held.get(name) || []).filter(h => h !== entry);
    if (list.length) held.set(name, list); else held.delete(name);
    tryGrant(name);
  };
  const lockManager = {
    async request(name, options, callback) {
      if (typeof options === 'function') { callback = options; options = {}; }
      name = String(name);
      const mode = options.mode === 'shared' ? 'shared' : 'exclusive';
      const signal = options.signal;
      if (signal && signal.aborted) throw signal.reason ?? new DOMException('The request was aborted.', 'AbortError');
      if (options.steal) {
        held.delete(name);
      }
      const current = held.get(name) || [];
      const free = current.length === 0 || (mode === 'shared' && current.every(h => h.mode === 'shared'));
      const queued = (lockQueues.get(name) || []).length > 0;
      if (options.ifAvailable && (!free || queued) && !options.steal) return callback(null);
      const entry = await new Promise((resolve, reject) => {
        const request = { mode, grant: resolve };
        if (!lockQueues.has(name)) lockQueues.set(name, []);
        lockQueues.get(name).push(request);
        if (signal) {
          signal.addEventListener('abort', () => {
            const queue = lockQueues.get(name) || [];
            const i = queue.indexOf(request);
            if (i >= 0) { queue.splice(i, 1); reject(signal.reason ?? new DOMException('The request was aborted.', 'AbortError')); }
          }, { once: true });
        }
        tryGrant(name);
      });
      try {
        return await callback({ name, mode });
      } finally {
        release(name, entry);
      }
    },
    async query() {
      const out = { held: [], pending: [] };
      for (const [name, list] of held) for (const h of list) out.held.push({ name, mode: h.mode, clientId: 'browsa' });
      for (const [name, queue] of lockQueues) for (const q of queue) out.pending.push({ name, mode: q.mode, clientId: 'browsa' });
      return out;
    },
  };
  try { Object.defineProperty(globalThis.navigator, 'locks', { value: lockManager, configurable: true }); } catch (e) {}

  // WebSocket, inside the worker. WebKit runs an extension's service worker on its process's main
  // thread, and opening a WebSocket there waits on that same thread: the worker freezes for good.
  // This stand-in asks Browsa to open the socket and passes frames over a native-messaging port.
  const NativeWebSocket = globalThis.WebSocket;
  const toBase64 = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromBase64 = (text) => Uint8Array.from(atob(text), c => c.charCodeAt(0)).buffer;

  class BrowsaWebSocket extends EventTarget {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    CONNECTING = 0; OPEN = 1; CLOSING = 2; CLOSED = 3;

    constructor(url, protocols) {
      super();
      const parsed = new URL(url, location.href);
      if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') throw new DOMException(`The URL's scheme must be either 'ws' or 'wss'.`, 'SyntaxError');
      this.url = parsed.href;
      this.readyState = 0;
      this.protocol = '';
      this.extensions = '';
      this.bufferedAmount = 0;
      this.binaryType = 'blob';
      this.onopen = this.onmessage = this.onerror = this.onclose = null;
      const list = protocols === undefined ? [] : Array.isArray(protocols) ? protocols : [protocols];
      try {
        this._port = chrome.runtime.connectNative('browsa.websocket');
      } catch (e) {
        queueMicrotask(() => this._fail(1006, ''));
        return;
      }
      this._port.onMessage.addListener((m) => this._received(m));
      this._port.onDisconnect.addListener(() => { if (this.readyState !== 3) this._fail(1006, ''); });
      this._port.postMessage({ type: 'open', url: this.url, protocols: list.map(String) });
    }

    _emit(type, init) {
      const e = type === 'message' ? new MessageEvent('message', init) : type === 'close' ? new CloseEvent('close', init) : new Event(type);
      const handler = this['on' + type];
      if (typeof handler === 'function') { try { handler.call(this, e); } catch (err) { setTimeout(() => { throw err; }); } }
      this.dispatchEvent(e);
    }

    _received(m) {
      if (!m || typeof m !== 'object') return;
      if (m.type === 'open' && this.readyState === 0) {
        this.readyState = 1;
        this.protocol = m.protocol || '';
        this._emit('open');
      } else if (m.type === 'message' && this.readyState === 1) {
        let data;
        if (typeof m.text === 'string') data = m.text;
        else {
          const buffer = fromBase64(m.binary || '');
          data = this.binaryType === 'arraybuffer' ? buffer : new Blob([buffer]);
        }
        this._emit('message', { data, origin: new URL(this.url).origin });
      } else if (m.type === 'sent') {
        this.bufferedAmount = Math.max(0, this.bufferedAmount - (m.bytes || 0));
      } else if (m.type === 'error') {
        this._fail(m.code || 1006, m.reason || '');
      } else if (m.type === 'close') {
        this._closed(m.code || 1005, m.reason || '', !!m.wasClean);
      }
    }

    _fail(code, reason) {
      if (this.readyState === 3) return;
      this._emit('error');
      this._closed(code, reason, false);
    }

    _closed(code, reason, wasClean) {
      if (this.readyState === 3) return;
      this.readyState = 3;
      this.bufferedAmount = 0;
      try { this._port && this._port.disconnect(); } catch (e) {}
      this._emit('close', { code, reason, wasClean });
    }

    send(data) {
      if (this.readyState === 0) throw new DOMException('Still in CONNECTING state.', 'InvalidStateError');
      if (this.readyState !== 1) return;
      const post = (message, bytes) => { this.bufferedAmount += bytes; this._port.postMessage(message); };
      if (typeof data === 'string') post({ type: 'send', text: data }, new TextEncoder().encode(data).length);
      else if (data instanceof ArrayBuffer) post({ type: 'send', binary: toBase64(data) }, data.byteLength);
      else if (ArrayBuffer.isView(data)) post({ type: 'send', binary: toBase64(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)) }, data.byteLength);
      else if (data instanceof Blob) {
        this.bufferedAmount += data.size;
        data.arrayBuffer().then(b => { this.bufferedAmount -= data.size; if (this.readyState === 1) post({ type: 'send', binary: toBase64(b) }, b.byteLength); });
      } else post({ type: 'send', text: String(data) }, String(data).length);
    }

    close(code, reason) {
      if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) throw new DOMException('Invalid close code.', 'InvalidAccessError');
      if (this.readyState >= 2) return;
      this.readyState = 2;
      try { this._port.postMessage({ type: 'close', code: code ?? 1000, reason: reason ?? '' }); } catch (e) { this._closed(1006, '', false); }
    }
  }
  globalThis.__browsaNativeWebSocket = NativeWebSocket;
  globalThis.WebSocket = BrowsaWebSocket;
})();
