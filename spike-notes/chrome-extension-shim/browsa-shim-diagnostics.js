// Spike diagnostics over a separate channel (a local web server), so they still arrive if the
// extension's own messaging and storage stall.
const browsaRawChrome = globalThis.chrome;
let browsaCallId = 0;
const browsaSink = (line) => {
  try { const r = browsaRawChrome.runtime.sendNativeMessage('browsa.log', { line: (typeof window === 'undefined' ? 'W ' : 'P ' + location.pathname + ' ') + line }); if (r && r.catch) r.catch(() => {}); } catch (e) {}
};
const browsaBrief = (x) => { try { return JSON.stringify(x, (k, v) => typeof v === 'function' ? 'fn' : v).slice(0, 140); } catch (e) { return String(x).slice(0, 140); } };
const browsaQuiet = new Set(['addListener', 'removeListener', 'hasListener', 'getURL', 'getManifest', 'get']);
browsaSink('shim loaded');
self.__browsaSkipBigSession = false;
self.__browsaFakeNative = true;
// Spike bisect: switch off pieces of the platform the extension uses (BROWSA_DISABLE below).
const BROWSA_DISABLE = new Set([]);
if (typeof window === 'undefined') {
  if (BROWSA_DISABLE.has('locks') && globalThis.navigator && navigator.locks) {
    const fake = { request: async (name, a, b) => { const cb = typeof a === 'function' ? a : b; return cb({ name, mode: 'exclusive' }); }, query: async () => ({ held: [], pending: [] }) };
    try { Object.defineProperty(navigator, 'locks', { value: fake, configurable: true }); } catch (e) { browsaSink('locks override failed ' + e); }
  }
  if (BROWSA_DISABLE.has('broadcast')) globalThis.BroadcastChannel = class { constructor(n) { this.name = n; } postMessage() {} close() {} addEventListener() {} removeEventListener() {} };
  if (BROWSA_DISABLE.has('sockets')) {
    globalThis.WebSocket = class { constructor() { throw new Error('disabled'); } };
    globalThis.EventSource = class { constructor() { throw new Error('disabled'); } };
  }
  browsaSink('disabled: ' + [...BROWSA_DISABLE].join(','));
}
// Spike: find what blocks the worker. Timers report when they fire and finish; blocking waits report.
if (typeof window === 'undefined') {
  const rawSetTimeout = globalThis.setTimeout, rawSetInterval = globalThis.setInterval;
  let timerId = 0;
  const where = () => { const st = String(new Error().stack || '').split('\n'); return (st[2] || '').replace(/webkit-extension:\/\/[^/]+/, '').trim().slice(0, 90); };
  const wrapTimer = (raw, kind) => function (fn, delay, ...rest) {
    if (typeof fn !== 'function') return raw(fn, delay, ...rest);
    const id = ++timerId, site = where();
    return raw(function (...a) {
      const t = Date.now();
      browsaSink('fire ' + kind + '#' + id + ' d=' + (delay | 0) + ' ' + site);
      try { return fn.apply(this, a); } finally { const ms = Date.now() - t; if (ms > 50) browsaSink('slow ' + kind + '#' + id + ' ' + ms + 'ms'); }
    }, delay, ...rest);
  };
  globalThis.setTimeout = wrapTimer(rawSetTimeout, 'timeout');
  globalThis.setInterval = wrapTimer(rawSetInterval, 'interval');
  if (globalThis.Atomics && Atomics.wait) {
    const rawWait = Atomics.wait;
    Atomics.wait = function (...a) { browsaSink('Atomics.wait timeout=' + a[3] + ' ' + where()); return rawWait.apply(this, a); };
  }
  const browsaT0 = Date.now();
  rawSetInterval(() => browsaSink('tick ' + (Date.now() - browsaT0) + 'ms'), 1000);
}
// Browsa spike: stand-ins for Chrome extension APIs WebKit doesn't have, so a background
// script that touches them at startup doesn't crash. Calls resolve to undefined; events never fire.
const browsaStub = () => new Proxy(function () { return Promise.resolve(undefined); }, {
  get(target, prop) {
    if (prop === 'addListener' || prop === 'removeListener') return () => {};
    if (prop === 'hasListener') return () => false;
    if (prop === 'then') return undefined;
    return browsaStub();
  },
  apply() { return Promise.resolve(undefined); },
});
const browsaRoots = [globalThis.chrome, globalThis.browser].filter((r, i, all) => r && all.indexOf(r) === i);
for (const root of browsaRoots) {
  for (const name of ['notifications', 'idle', 'management', 'privacy', 'downloads', 'offscreen', 'cookies', 'sidePanel', 'identity']) {
    try { if (typeof root[name] === 'undefined') root[name] = browsaStub(); } catch (e) { console.warn('browsa shim', name, e); }
  }
}
// Events some namespaces lack in WebKit. Listeners are accepted and never called.
const browsaEvents = {
  webNavigation: ['onCreatedNavigationTarget', 'onBeforeNavigate', 'onCommitted', 'onCompleted', 'onDOMContentLoaded', 'onErrorOccurred', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onTabReplaced'],
  webRequest: ['onBeforeRedirect', 'onAuthRequired', 'onBeforeRequest', 'onCompleted', 'onErrorOccurred', 'onHeadersReceived', 'onResponseStarted', 'onSendHeaders', 'onBeforeSendHeaders'],
  tabs: ['onCreated', 'onRemoved', 'onUpdated', 'onActivated', 'onReplaced', 'onHighlighted', 'onMoved', 'onAttached', 'onDetached', 'onZoomChange'],
  windows: ['onCreated', 'onRemoved', 'onFocusChanged', 'onBoundsChanged'],
  runtime: ['onStartup', 'onInstalled', 'onSuspend', 'onSuspendCanceled', 'onUpdateAvailable', 'onConnectExternal', 'onMessageExternal', 'onRestartRequired'],
  action: ['onClicked', 'onUserSettingsChanged'],
  contextMenus: ['onClicked'],
  alarms: ['onAlarm'],
  permissions: ['onAdded', 'onRemoved'],
  commands: ['onCommand'],
};
const browsaMissing = [];
for (const root of browsaRoots) {
  for (const [ns, events] of Object.entries(browsaEvents)) {
    if (!root[ns]) continue;
    for (const ev of events) {
      if (root[ns][ev]) continue;
      try { root[ns][ev] = { addListener() {}, removeListener() {}, hasListener() { return false; } }; browsaMissing.push(ns + '.' + ev); } catch (e) {}
    }
  }
}

// Managed (enterprise policy) storage: always empty.
const browsaEvent = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; } });
for (const root of browsaRoots) {
  try {
    if (root.storage && !root.storage.managed) {
      root.storage.managed = { get: async () => ({}), getBytesInUse: async () => 0, onChanged: browsaEvent() };
      browsaMissing.push('storage.managed');
    }
  } catch (e) {}
}

// WebKit's API objects ignore new properties, so wrap the roots instead: missing namespaces,
// events and methods come back as stand-ins; everything WebKit has is passed through.
// runtime.onMessage with Chrome's rules: every listener sees the message, a listener that returns
// true (or a promise) answers it, and one returning false just declines. WebKit settles the reply on
// the first listener's return value, so put one dispatcher in front of them all.
let browsaDispatcher = null;
const browsaOnMessage = (event) => {
  if (browsaDispatcher) return browsaDispatcher;
  const listeners = [];
  const dispatch = (message, sender, sendResponse) => {
    try { self.__browsaRecord && self.__browsaRecord('dispatch start ' + JSON.stringify(message).slice(0, 80) + ' from ' + (sender && sender.url)); } catch (e) {}
    if (message && message.name === 'browsa-ping') { sendResponse({ pong: true, listeners: listeners.length, log: (self.__browsaErrors || []).slice(-25) }); return false; }
    let answered = false;
    const respond = (value) => { if (!answered) { answered = true; try { self.__browsaRecord && self.__browsaRecord('respond ' + (message && message.name) + ' ' + JSON.stringify(value).slice(0, 120)); } catch (e) {} sendResponse(value); } };
    let keepOpen = false;
    for (const fn of listeners.slice()) {
      let result;
      try { result = fn(message, sender, respond); } catch (e) { console.error('onMessage listener threw', e); continue; }
      if (result === true) keepOpen = true;
      else if (result && typeof result.then === 'function') { keepOpen = true; result.then(respond, e => respond(undefined)); }
    }
    try { self.__browsaRecord && self.__browsaRecord('dispatch ' + (message && message.name) + ' listeners=' + listeners.length + ' keepOpen=' + keepOpen + ' answered=' + answered); } catch (e) {}
    return keepOpen;
  };
  event.addListener(dispatch);
  browsaDispatcher = {
    addListener(fn) { if (!listeners.includes(fn)) listeners.push(fn); },
    removeListener(fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
    hasListener(fn) { return listeners.includes(fn); },
    hasListeners() { return listeners.length > 0; },
  };
  return browsaDispatcher;
};
const browsaMissingSeen = new Set();
const browsaWrap = (target, path) => new Proxy(target, {
  get(t, prop) {
    const v = Reflect.get(t, prop);
    if (typeof prop === 'symbol') return v;
    if (!path.includes('.')) { const k = path + '.' + String(prop); if (!browsaMissingSeen.has('ns:' + k)) { browsaMissingSeen.add('ns:' + k); browsaSink('ns ' + k + ' ' + typeof v); } }
    if (v === undefined && prop === 'managed' && path.endsWith('.storage')) {
      return { get: async () => ({}), getBytesInUse: async () => 0, onChanged: browsaEvent() };
    }
    if (v === undefined) {
      const name = path + '.' + String(prop);
      if (!browsaMissingSeen.has(name)) { browsaMissingSeen.add(name); try { self.__browsaRecord ? self.__browsaRecord('stand-in: ' + name) : (self.__browsaPending ||= []).push('stand-in: ' + name); } catch (e) {} }
      return /^on[A-Z]/.test(String(prop)) ? browsaEvent() : browsaStub();
    }
    if (prop === 'connectNative' && path.endsWith('.runtime') && self.__browsaFakeNative) {
      // No native app in standalone mode: hand back a port that closes straight away, without
      // asking WebKit (whose failed native connections appear to wedge the extension's messaging).
      return (application) => {
        browsaSink('fake connectNative ' + application);
        const listeners = { message: [], disconnect: [] };
        const ev = (k) => ({ addListener(f) { listeners[k].push(f); }, removeListener(f) { const i = listeners[k].indexOf(f); if (i >= 0) listeners[k].splice(i, 1); }, hasListener(f) { return listeners[k].includes(f); } });
        const port = { name: '', sender: undefined, onMessage: ev('message'), onDisconnect: ev('disconnect'), postMessage() {}, disconnect() {} };
        setTimeout(() => { for (const f of listeners.disconnect.slice()) { try { f(port); } catch (e) {} } }, 0);
        return port;
      };
    }
    if (typeof window === 'undefined' && BROWSA_DISABLE.has('menus') && path.endsWith('.contextMenus') && (prop === 'create' || prop === 'removeAll' || prop === 'update' || prop === 'remove')) return (...a) => { const cb = a.find(x => typeof x === 'function'); if (cb) setTimeout(cb, 0); return prop === 'create' ? 'x' : Promise.resolve(); };
    if (prop === 'onMessage' && path.endsWith('.runtime') && v) return browsaOnMessage(v);
    if (typeof v === 'function' && path.endsWith('.runtime') && (prop === 'sendMessage' || prop === 'connect')) {
      const where = typeof window === 'undefined' ? 'worker' : location.pathname;
      const log = (line) => { try { self.__browsaRecord ? self.__browsaRecord(line) : (self.__browsaPending ||= []).push(line); } catch (e) {} };
      const brief = (m) => { try { return JSON.stringify(m).slice(0, 160); } catch (e) { return String(m); } };
      if (prop === 'sendMessage') {
        return (...args) => {
          const msg = args.find(a => a && typeof a === 'object');
          const id = Math.random().toString(36).slice(2, 6);
          log(where + ' sendMessage#' + id + ' ' + brief(msg));
          const r = v.apply(t, args);
          if (r && typeof r.then === 'function') {
            const timer = setTimeout(() => log(where + ' sendMessage#' + id + ' NO REPLY after 5s'), 5000);
            r.then(x => { clearTimeout(timer); log(where + ' sendMessage#' + id + ' reply ' + brief(x)); },
                   e => { clearTimeout(timer); log(where + ' sendMessage#' + id + ' error ' + String(e)); });
          }
          return r;
        };
      }
      return (...args) => {
        const port = v.apply(t, args);
        const name = (args.find(a => a && typeof a === 'object') || {}).name;
        log(where + ' connect ' + name);
        try {
          port.onMessage.addListener(m => log(where + ' port ' + name + ' <- ' + brief(m)));
          port.onDisconnect.addListener(() => log(where + ' port ' + name + ' disconnected ' + String(chrome.runtime.lastError && chrome.runtime.lastError.message)));
          const post = port.postMessage.bind(port);
          port.postMessage = (m) => { log(where + ' port ' + name + ' -> ' + brief(m)); return post(m); };
        } catch (e) { log('port wrap failed ' + e); }
        return port;
      };
    }
    if (typeof v === 'function') {
      if (v.__browsaStub) return v;
      if (browsaQuiet.has(String(prop)) && !(String(prop) === 'get' && path.endsWith('.local'))) return v.bind(t);
      const name = path + '.' + String(prop);
      return (...args) => {
        const id = ++browsaCallId;
        if (self.__browsaSkipBigSession && name.endsWith('storage.session.set') && args[0] && ['compromised-sites', '2fa-sites', 'passkey-sites'].some(k => k in args[0])) {
          browsaSink('SKIPPED session.set ' + Object.keys(args[0]).join(',') + ' ' + JSON.stringify(args[0]).length + ' bytes');
          return Promise.resolve();
        }
        browsaSink('call#' + id + ' ' + name + ' ' + browsaBrief(args));
        let r;
        try { r = v.apply(t, args); } catch (e) { browsaSink('throw#' + id + ' ' + name + ' ' + e); throw e; }
        if (r && typeof r.then === 'function') {
          const timer = setTimeout(() => browsaSink('PENDING-5s#' + id + ' ' + name), 5000);
          r.then(() => { clearTimeout(timer); browsaSink('ok#' + id); }, e => { clearTimeout(timer); browsaSink('rej#' + id + ' ' + e); });
        }
        return r;
      };
    }
    if (v && typeof v === 'object' && path.split('.').length < 3) return browsaWrap(v, path + '.' + String(prop));
    return v;
  },
});
// WebKit only delivers messages to onMessage listeners that exist when the worker's script first
// runs, so install the dispatcher now; the extension's own listeners join it whenever they're added.
if ((typeof window === 'undefined' || location.pathname.includes('_generated_background') || location.pathname === '/') && globalThis.chrome && chrome.runtime && chrome.runtime.onMessage) browsaOnMessage(chrome.runtime.onMessage);
for (const key of ['chrome', 'browser']) {
  if (!globalThis[key]) continue;
  const wrapped = browsaWrap(globalThis[key], key);
  try { globalThis[key] = wrapped; } catch (e) {}
  if (globalThis[key] !== wrapped) {
    try { Object.defineProperty(globalThis, key, { value: wrapped, configurable: true, writable: true }); } catch (e) {}
  }
}

// Spike diagnostics: keep errors where the test can read them (the worker has no window).
self.__browsaErrors = [];
const browsaRecord = (line) => {
  self.__browsaErrors.push(line);
  browsaSink('log ' + String(line).slice(0, 300));
  try { browsaRawChrome.storage.local.set({ [typeof window === 'undefined' ? '__browsaWorker' : '__browsaErrors']: self.__browsaErrors.slice(-150) }); } catch (e) {}
};
self.addEventListener('error', e => browsaRecord((typeof window === 'undefined' ? 'worker ' : 'page ') + String(e.message) + ' @' + e.filename + ':' + e.lineno));
self.addEventListener('unhandledrejection', e => browsaRecord((typeof window === 'undefined' ? 'worker ' : 'page ') + 'rejection: ' + String(e.reason && e.reason.message) + ' :: ' + String(e.reason && (e.reason.stack || e.reason)).slice(0, 300)));
const browsaConsoleError = console.error.bind(console);
console.error = (...a) => { browsaRecord('console.error: ' + a.map(x => String(x && (x.stack || x))).join(' ').slice(0, 400)); browsaConsoleError(...a); };
if (typeof window === 'undefined') browsaRecord('worker started ' + new Date().toISOString());
for (const level of ['warn', 'info', 'log']) {
  const original = console[level].bind(console);
  console[level] = (...a) => { browsaRecord(level + ': ' + a.map(x => { try { return typeof x === 'string' ? x : JSON.stringify(x); } catch (e) { return String(x); } }).join(' ').slice(0, 300)); original(...a); };
}
if (typeof window === 'undefined') browsaRecord('same object each access: ' + (chrome.webNavigation === chrome.webNavigation) + ', filled survives: ' + !!chrome.webNavigation.onCreatedNavigationTarget);

if (self.__browsaPending) for (const l of self.__browsaPending) browsaRecord(l);
browsaRecord('wrapped chrome: ' + (typeof globalThis.chrome.storage.managed));
self.__browsaRecord = browsaRecord;
if (typeof window === 'undefined') {
  const browsaStart = Date.now();
  setInterval(() => { browsaSink('heartbeat ' + Math.round((Date.now() - browsaStart) / 1000) + 's'); try { browsaRawChrome.storage.local.set({ __browsaHeartbeat: Math.round((Date.now() - browsaStart) / 1000) + 's at ' + new Date().toISOString() }); } catch (e) {} }, 2000);
}
