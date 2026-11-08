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
    if (v === undefined && prop === 'managed' && path.endsWith('.storage')) {
      return { get: async () => ({}), getBytesInUse: async () => 0, onChanged: browsaEvent() };
    }
    if (v === undefined) {
      const name = path + '.' + String(prop);
      if (!browsaMissingSeen.has(name)) { browsaMissingSeen.add(name); try { self.__browsaRecord ? self.__browsaRecord('stand-in: ' + name) : (self.__browsaPending ||= []).push('stand-in: ' + name); } catch (e) {} }
      return /^on[A-Z]/.test(String(prop)) ? browsaEvent() : browsaStub();
    }
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
    if (typeof v === 'function') return v.__browsaStub ? v : v.bind(t);
    if (v && typeof v === 'object' && path.split('.').length < 3) return browsaWrap(v, path + '.' + String(prop));
    return v;
  },
});
// WebKit only delivers messages to onMessage listeners that exist when the worker's script first
// runs, so install the dispatcher now; the extension's own listeners join it whenever they're added.
if (typeof window === 'undefined' && globalThis.chrome && chrome.runtime && chrome.runtime.onMessage) browsaOnMessage(chrome.runtime.onMessage);
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
  try { chrome.storage.local.set({ [typeof window === 'undefined' ? '__browsaWorker' : '__browsaErrors']: self.__browsaErrors.slice(-150) }); } catch (e) {}
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
  setInterval(() => { try { chrome.storage.local.set({ __browsaHeartbeat: Math.round((Date.now() - browsaStart) / 1000) + 's at ' + new Date().toISOString() }); } catch (e) {} }, 2000);
}
