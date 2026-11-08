// Browsa's Chrome compatibility layer for WebKit (see ChromeCompatibility.swift).
//
// Chrome extensions from the Web Store expect a few APIs WebKit doesn't have. Browsa puts this file
// in front of their background script and pages, so code that touches those APIs at startup keeps
// running: missing namespaces and methods become stand-ins that resolve to undefined, missing
// events accept listeners and never fire. Grown from the 1Password spike (7 Nov 2026), without its
// diagnostics. Real APIs pass straight through.
(() => {
  if (globalThis.__browsaShim) return;
  globalThis.__browsaShim = true;

  const stub = () => new Proxy(function () { return Promise.resolve(undefined); }, {
    get(_, prop) {
      if (prop === 'addListener' || prop === 'removeListener') return () => {};
      if (prop === 'hasListener') return () => false;
      if (prop === 'then') return undefined;
      return stub();
    },
    apply() { return Promise.resolve(undefined); },
  });
  const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; } });
  const managedStorage = () => ({ get: async () => ({}), getBytesInUse: async () => 0, onChanged: event() });

  // runtime.onMessage with Chrome's rules: every listener sees the message; one that returns true
  // (or a promise) answers it. WebKit settles the reply on the first listener's return value, and
  // only delivers to listeners present when the worker first runs, so one dispatcher fronts them all.
  let dispatcher = null;
  const onMessage = (real) => {
    if (dispatcher) return dispatcher;
    const listeners = [];
    real.addListener((message, sender, sendResponse) => {
      let answered = false;
      const respond = (value) => { if (!answered) { answered = true; sendResponse(value); } };
      let keepOpen = false;
      for (const fn of listeners.slice()) {
        let result;
        try { result = fn(message, sender, respond); } catch (e) { console.error('onMessage listener threw', e); continue; }
        if (result === true) keepOpen = true;
        else if (result && typeof result.then === 'function') { keepOpen = true; result.then(respond, () => respond(undefined)); }
      }
      return keepOpen;
    });
    dispatcher = {
      addListener(fn) { if (!listeners.includes(fn)) listeners.push(fn); },
      removeListener(fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
      hasListener(fn) { return listeners.includes(fn); },
      hasListeners() { return listeners.length > 0; },
    };
    return dispatcher;
  };

  // WebKit's API objects ignore new properties, so wrap the roots instead.
  const wrap = (target, path) => new Proxy(target, {
    get(t, prop) {
      const v = Reflect.get(t, prop);
      if (typeof prop === 'symbol') return v;
      if (v === undefined) {
        if (prop === 'managed' && path.endsWith('.storage')) return managedStorage();
        return /^on[A-Z]/.test(String(prop)) ? event() : stub();
      }
      if (prop === 'onMessage' && path.endsWith('.runtime')) return onMessage(v);
      if (typeof v === 'function') return v.bind(t);
      if (v && typeof v === 'object' && path.split('.').length < 3) return wrap(v, path + '.' + String(prop));
      return v;
    },
  });

  const isWorker = typeof window === 'undefined';
  if (isWorker && globalThis.chrome && chrome.runtime && chrome.runtime.onMessage) onMessage(chrome.runtime.onMessage);
  if (!globalThis.chrome && globalThis.browser) globalThis.chrome = globalThis.browser;
  for (const key of ['chrome', 'browser']) {
    if (!globalThis[key]) continue;
    const wrapped = wrap(globalThis[key], key);
    try { globalThis[key] = wrapped; } catch (e) {}
    if (globalThis[key] !== wrapped) {
      try { Object.defineProperty(globalThis, key, { value: wrapped, configurable: true, writable: true }); } catch (e) {}
    }
  }
})();
