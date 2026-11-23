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

  // From Search (Office Commun, MIT, ExtensionShims.swift): small gaps and one trap.
  // Symbol.dispose / asyncDispose, which bundled TypeScript (Bitwarden) uses as class keys.
  for (const name of ['dispose', 'asyncDispose']) {
    if (Symbol[name] === undefined) { try { Object.defineProperty(Symbol, name, { value: Symbol.for('Symbol.' + name) }); } catch (e) {} }
  }
  // requestIdleCallback, which WebKit took back out (bug 287681) and Proton Pass relies on.
  if (typeof globalThis.requestIdleCallback !== 'function') {
    const idle = new Map();
    let idleId = 0;
    globalThis.requestIdleCallback = (callback) => {
      const id = ++idleId;
      idle.set(id, setTimeout(() => {
        if (!idle.delete(id)) return;
        const start = Date.now();
        callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
      }, 1));
      return id;
    };
    globalThis.cancelIdleCallback = (id) => { const t = idle.get(id); if (t !== undefined) { idle.delete(id); clearTimeout(t); } };
  }
  // WebKit finds a page's extension APIs through the chrome and browser globals when it delivers an
  // event. An extension that puts its own object there, one that hides the APIs (Proton Pass wraps
  // chrome in a Proxy), cuts itself off: nothing arrives any more. Made accessors, they keep WebKit's
  // object unless a replacement still carries runtime.id. browser stays configurable (a page may
  // declare its own), and in the worker keeps WebKit's own (webextension-polyfill would replace it).
  for (const key of ['chrome', 'browser']) {
    const d = Object.getOwnPropertyDescriptor(globalThis, key);
    if (!d || !d.configurable || !d.hasOwnProperty('value')) continue;
    let value = globalThis[key];
    const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
    const ownBrowser = key === 'browser' && isWorker;
    try {
      Object.defineProperty(globalThis, key, { configurable: key === 'browser', enumerable: d.enumerable,
        get: () => value, set: (v) => { if (!ownBrowser && carries(v)) value = v; } });
    } catch (e) {}
  }

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
    // Real macOS notifications, through Browsa (ExtensionBridges.swift). Clicks bring Browsa forward;
    // onClicked/onClosed don't fire yet.
    notifications: () => ({
      create: (...args) => {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const id = typeof args[0] === 'string' ? args[0] : `browsa-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
        const o = (typeof args[0] === 'string' ? args[1] : args[0]) || {};
        const p = bridge('browsa.notifications', { action: 'create', id, title: o.title || '', message: o.message || o.contextMessage || '' }).then(() => id);
        if (cb) p.then(cb, () => cb(id));
        return p;
      },
      update: resolves(false),
      clear: (id, cb) => { const p = bridge('browsa.notifications', { action: 'clear', id }).then(() => true, () => false); if (cb) p.then(cb); return p; },
      getAll: (cb) => { const p = Promise.resolve({}); if (cb) p.then(cb); return p; },
      getPermissionLevel: (cb) => { const p = Promise.resolve('granted'); if (cb) p.then(cb); return p; },
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
    // Saved to the Downloads folder by Browsa and listed in its Downloads panel. blob: URLs are read
    // here first, since only this extension can read them.
    downloads: () => ({
      download: (o = {}, cb) => {
        const p = (async () => {
          let url = o.url || '';
          if (url.startsWith('blob:')) {
            const buf = await (await fetch(url)).arrayBuffer();
            if (buf.byteLength > 50 * 1024 * 1024) throw new Error('downloads.download: blobs over 50 MB aren\'t supported in Browsa yet');
            let bin = '';
            const bytes = new Uint8Array(buf);
            for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            url = 'data:application/octet-stream;base64,' + btoa(bin);
          }
          return bridge('browsa.downloads', { action: 'download', url, filename: o.filename || '' });
        })();
        if (cb) p.then(cb, () => cb(undefined));
        return p;
      },
      search: resolves([]), open: unsupported('downloads.open'),
      onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event(),
    }),
    // A hidden extension page Browsa keeps for the extension (ExtensionOffscreen.swift).
    offscreen: () => ({
      createDocument: (p) => offscreenCall('create', p && p.url).then(() => undefined),
      closeDocument: () => offscreenCall('close').then(() => undefined),
      hasDocument: () => offscreenCall('has').then((url) => !!url),
      Reason: offscreenReasons,
    }),
    // The side panel is Browsa's right panel. open() shows it; openPanelOnActionClick makes the toolbar
    // button open it, as in Chrome.
    sidePanel: () => ({
      // Browsa's panel isn't per tab: the latest page set is the one shown (Claude sets its page here,
      // with none in its manifest).
      setOptions: (o = {}) => bridge('browsa.sidepanel', { action: 'options', path: typeof o.path === 'string' ? o.path : null, enabled: o.enabled !== false }).then(() => undefined),
      getOptions: resolves({}),
      setPanelBehavior: (b = {}) => bridge('browsa.sidepanel', { action: 'behavior', openPanelOnActionClick: !!b.openPanelOnActionClick }).then(() => undefined),
      getPanelBehavior: () => bridge('browsa.sidepanel', { action: 'getBehavior' }),
      open: () => bridge('browsa.sidepanel', { action: 'open' }).then(() => undefined),
    }),
    // Tab groups: Browsa has none to report. Constants are read at startup (Claude reads
    // TAB_GROUP_ID_NONE and Color); queries find nothing and changes are refused.
    tabGroups: () => ({
      TAB_GROUP_ID_NONE: -1,
      Color: Object.fromEntries(['GREY', 'BLUE', 'RED', 'YELLOW', 'GREEN', 'PINK', 'PURPLE', 'CYAN', 'ORANGE'].map(c => [c, c.toLowerCase()])),
      query: resolves([]), get: unsupported('tabGroups.get'), update: unsupported('tabGroups.update'), move: unsupported('tabGroups.move'),
      onCreated: event(), onUpdated: event(), onMoved: event(), onRemoved: event(),
    }),
    // The DevTools protocol, which Browsa doesn't offer extensions. Listeners can be added (Claude adds
    // them at startup); attaching is refused, so features built on it say they can't run.
    debugger: () => ({
      attach: unsupported('debugger.attach'), detach: unsupported('debugger.detach'),
      sendCommand: unsupported('debugger.sendCommand'), getTargets: resolves([]),
      onEvent: event(), onDetach: event(),
    }),
    // Sign-in through Browsa (ExtensionAuth.swift): the provider in a tab, or quietly in a hidden view;
    // the answer is the https://<id>.chromiumapp.org/ address the provider redirects to.
    identity: () => ({ launchWebAuthFlow: (details = {}, cb) => {
      const p = bridge('browsa.identity', { url: String(details.url || ''), interactive: !!details.interactive,
        timeout: details.timeoutMsForNonInteractive || 5000 });
      if (cb) p.then(cb, (e) => { try { chrome.runtime.lastError = e; } catch (x) {} cb(undefined); });
      return p;
    }, getRedirectURL: (p = '') => `https://${chrome.runtime.id}.chromiumapp.org/${p}`, onSignInChanged: event() }),
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
  const offscreenCall = (action, url) => chrome.runtime.sendNativeMessage('browsa.offscreen', { action, url });
  const bridge = (name, body) => chrome.runtime.sendNativeMessage(name, body);
  const offscreenReasons = Object.fromEntries(['TESTING', 'AUDIO_PLAYBACK', 'IFRAME_SCRIPTING', 'DOM_SCRAPING', 'BLOBS', 'DOM_PARSER',
    'USER_MEDIA', 'DISPLAY_MEDIA', 'WEB_RTC', 'CLIPBOARD', 'LOCAL_STORAGE', 'WORKERS', 'BATTERY_STATUS', 'MATCH_MEDIA', 'GEOLOCATION'].map(r => [r, r]));
  // Constants and small helpers Chrome has on namespaces WebKit does provide. Extensions read some of
  // them at startup (chrome.offscreen.Reason.CLIPBOARD, chrome.scripting.ExecutionWorld.MAIN).
  const extras = {
    // Only the offscreen document is reported; other contexts aren't tracked.
    // The offscreen document and side panel pages; other contexts aren't tracked.
    runtime: {
      // Read by Claude's side panel to check where it is.
      ContextType: { TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS' },
      getContexts: (filter = {}) => {
      const types = filter.contextTypes;
      const wants = (t) => !types || types.includes(t);
      const context = (type, url, id) => ({ contextType: type, documentUrl: url, documentOrigin: new URL(url).origin,
        contextId: id, tabId: -1, windowId: -1, frameId: -1, incognito: false });
      const offscreen = wants('OFFSCREEN_DOCUMENT')
        ? offscreenCall('has').then((url) => url ? [context('OFFSCREEN_DOCUMENT', url, 'browsa-offscreen')] : [], () => []) : Promise.resolve([]);
      const panels = wants('SIDE_PANEL')
        ? bridge('browsa.sidepanel', { action: 'contexts' }).then((urls) => (urls || []).map((u, i) => context('SIDE_PANEL', u, 'browsa-panel-' + i)), () => [])
        : Promise.resolve([]);
      return Promise.all([offscreen, panels]).then(([a, b]) => {
        let all = a.concat(b);
        if (filter.documentUrls) all = all.filter((c) => filter.documentUrls.includes(c.documentUrl));
        return all;
      });
    } },
    scripting: { ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' } },
    tabs: { TAB_ID_NONE: -1, TAB_INDEX_NONE: -1 },
    windows: { WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2 },
    offscreen: { Reason: offscreenReasons },
  };
  const missing = [];
  for (const root of roots) {
    for (const [name, make] of Object.entries(namespaces)) {
      if (root[name] === undefined) {
        try { root[name] = keep(make()); missing.push(name); } catch (e) {}
      } else if (name === 'sidePanel') {
        // WebKit has its own chrome.sidePanel, which Browsa can't show: route its calls to Browsa's panel.
        const ours = keep(make());
        try { Object.defineProperty(root, name, { value: ours, configurable: true, writable: true }); }
        catch (e) { try { Object.assign(root[name], ours); } catch (e2) {} }
        missing.push('sidePanel (replaced)');
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
    for (const [ns, values] of Object.entries(extras)) {
      const target = root[ns];
      if (!target) continue;
      keep(target);
      for (const [name, value] of Object.entries(values)) {
        if (target[name] === undefined) {
          try { target[name] = value; missing.push(`${ns}.${name}`); } catch (e) {}
        }
      }
    }
    // Each storage area's own onChanged (chrome.storage.session.onChanged…), which Chrome has and
    // WebKit doesn't: fed from chrome.storage.onChanged for that area. Claude's background adds a
    // listener to storage.session.onChanged at startup and stopped there.
    if (root.storage && root.storage.onChanged && typeof root.storage.onChanged.addListener === 'function') {
      for (const area of ['local', 'sync', 'session']) {
        const target = root.storage[area];
        if (!target || target.onChanged !== undefined) continue;
        const listeners = new Set();
        try {
          keep(target).onChanged = {
            addListener(fn) { if (typeof fn === 'function') listeners.add(fn); },
            removeListener(fn) { listeners.delete(fn); },
            hasListener(fn) { return listeners.has(fn); },
            hasListeners() { return listeners.size > 0; },
          };
          root.storage.onChanged.addListener((changes, areaName) => {
            if (areaName !== area) return;
            for (const fn of [...listeners]) { try { fn(changes); } catch (e) { setTimeout(() => { throw e; }); } }
          });
          missing.push(`storage.${area}.onChanged`);
        } catch (e) {}
      }
    }
    if (root.storage && root.storage.managed === undefined) {
      try {
        // Chrome's callback form too: Grammarly passes a callback and waits for it (timing out otherwise).
        const answer = (value) => (...args) => { const cb = args.find(a => typeof a === 'function'); if (cb) setTimeout(() => cb(value)); return Promise.resolve(value); };
        keep(root.storage).managed = { get: answer({}), getBytesInUse: answer(0), onChanged: event() };
        missing.push('storage.managed');
      } catch (e) {}
    }
  }
  // Permissions Browsa provides itself (above) aren't ones WebKit knows: asking about them throws
  // ("'downloads' is not a valid permission"), which stopped FireShot saving. Answer yes for them,
  // and pass the rest to WebKit.
  const bridged = ['downloads', 'notifications', 'sidePanel'];
  // An extension given <all_urls> holds it as every website, *://*/* (WebKitExtensions.everyWebsite),
  // so other extensions' pages stay out of reach as in Chrome. Asking about <all_urls> asks about that.
  const websites = (origins) => origins.map((o) => (o === '<all_urls>' ? '*://*/*' : o));
  for (const root of roots) {
    const perms = root.permissions;
    if (!perms) continue;
    for (const fn of ['contains', 'request']) {
      const original = typeof perms[fn] === 'function' ? perms[fn].bind(perms) : null;
      if (!original) continue;
      const wrapped = (p = {}, cb) => {
        const asked = Array.isArray(p.permissions) ? p.permissions : [];
        const rest = asked.filter((x) => !bridged.includes(x));
        const origins = websites(Array.isArray(p.origins) ? p.origins : []);
        let result;
        if (!rest.length && !origins.length) result = Promise.resolve(true);
        else {
          const ask = origins.length ? { ...p, permissions: rest, origins } : { ...p, permissions: rest };
          try { result = Promise.resolve(original(ask)); } catch (e) { result = Promise.reject(e); }
        }
        if (cb) { result.then((v) => cb(!!v), () => cb(false)); return undefined; }
        return result;
      };
      try { Object.defineProperty(perms, fn, { value: wrapped, configurable: true, writable: true }); }
      catch (e) { try { perms[fn] = wrapped; } catch (e2) {} }
    }
    try { keep(perms); } catch (e) {}
  }
  globalThis.__browsaCompatMissing = missing;

  // These are Chrome builds of the extensions, and some decide what they're running in from the user
  // agent (Bitwarden's device type is null without " Chrome/", and its background throws). Inside the
  // extension only, the user agent says Chrome; websites still see Browsa's own. Kept at Chrome's
  // stable version, as ChromeWebStore.productVersion is: 1Password opens its popup to unlock only from
  // Chrome 149 (found by Search, Office Commun).
  const ua = globalThis.navigator && navigator.userAgent;
  if (ua && !ua.includes(' Chrome/')) {
    const chromeUA = ua.replace(/ Version\/[\d.]+/, '').replace(/ Safari\/[\d.]+/, '') + ' Chrome/156.0.0.0 Safari/537.36';
    try { Object.defineProperty(Object.getPrototypeOf(navigator), 'userAgent', { get: () => chromeUA, configurable: true }); } catch (e) {}
    try { Object.defineProperty(Object.getPrototypeOf(navigator), 'vendor', { get: () => 'Google Inc.', configurable: true }); } catch (e) {}
  }

  // Copying from an extension page without a click (Chrome allows it with the clipboardWrite
  // permission, e.g. Paper Snapshot's offscreen page). WebKit refuses document.execCommand('copy')
  // there, so when it does, the page's own copy handler runs on a stand-in clipboard and Browsa
  // writes what it set (ExtensionOffscreen.swift, "browsa.clipboard").
  if (!isWorker && globalThis.document && typeof document.execCommand === 'function') {
    const execCommand = document.execCommand;
    document.execCommand = function (command, ...rest) {
      const done = execCommand.call(this, command, ...rest);
      if (done || String(command).toLowerCase() !== 'copy' || typeof DataTransfer !== 'function') return done;
      try {
        const data = new DataTransfer();
        const copy = new ClipboardEvent('copy', { clipboardData: data, bubbles: true, cancelable: true });
        (document.activeElement || document).dispatchEvent(copy);
        const items = {};
        for (const type of data.types) items[type] = data.getData(type);
        if (!Object.keys(items).length) return false;
        const sent = chrome.runtime.sendNativeMessage('browsa.clipboard', { items });
        if (sent && sent.catch) sent.catch(() => {});
        return true;
      } catch (e) { return false; }
    };
  }

  // What the extension's background sends its own pages, and storage changes, relayed over a
  // BroadcastChannel (one origin: the extension's). WebKit doesn't bring every message to every page
  // of the extension, and a side panel or popup waiting on one (Claude's after sign-in, Bitwarden's
  // sync) never heard it. Each copy is paired by its content: a page that heard WebKit's copy skips
  // the relayed one and the other way round; unpaired copies are forgotten after 5 s. The idea is
  // Search's (Office Commun, MIT, ExtensionShims.swift).
  const runtime0 = globalThis.chrome && globalThis.chrome.runtime;
  if (typeof BroadcastChannel === 'function' && runtime0 && runtime0.onMessage && typeof runtime0.sendMessage === 'function') {
    const channel = new BroadcastChannel('browsa-relay');
    const me = Math.random().toString(36).slice(2);
    const ownPlace = (() => { try { return runtime0.getURL(''); } catch (e) { return ''; } })();
    const keyOf = (m) => { try { const k = JSON.stringify(m, (_, v) => v && typeof v === 'object' && !Array.isArray(v)
      ? Object.fromEntries(Object.keys(v).sort().map((x) => [x, v[x]])) : v); return k && k.length < 200000 ? k : null; } catch (e) { return null; } };
    const native = new Map(), relayed = new Map();
    const bump = (map, key, by) => {
      const now = Date.now();
      for (const [k, v] of map) if (now - v.at > 5000) map.delete(k);
      const n = ((map.get(key) || {}).n || 0) + by;
      if (n > 0) map.set(key, { n, at: now }); else map.delete(key);
    };
    const has = (map, key) => { const v = map.get(key); return !!v && Date.now() - v.at <= 5000 && v.n > 0; };
    const listeners = new Map();   // the extension's onMessage listener -> ours
    const ownSender = (s) => !!s && s.id === runtime0.id && typeof s.url === 'string' && !!ownPlace && s.url.startsWith(ownPlace);
    const onMessage = runtime0.onMessage;
    const add = onMessage.addListener.bind(onMessage), remove = onMessage.removeListener.bind(onMessage);
    const wrapped = (fn) => function (message, sender, respond) {
      const key = !isWorker && ownSender(sender) ? keyOf(message) : null;
      if (key && has(relayed, key)) { bump(relayed, key, -1); return; }
      if (key) bump(native, key, 1);
      return fn.call(this, message, sender, respond);
    };
    try {
      onMessage.addListener = function (fn) { if (typeof fn !== 'function') return add(fn); const w = wrapped(fn); listeners.set(fn, w); return add(w); };
      onMessage.removeListener = function (fn) { const w = listeners.get(fn); listeners.delete(fn); return remove(w || fn); };
      onMessage.hasListener = function (fn) { return listeners.has(fn); };
      keep(onMessage);
    } catch (e) {}
    const send = runtime0.sendMessage.bind(runtime0);
    try {
      runtime0.sendMessage = function (...args) {
        // Only messages for the extension itself (no other extension's id first).
        const own = !(typeof args[0] === 'string' && args.length > 1 && args[0] !== runtime0.id);
        const message = own ? (typeof args[0] === 'string' && args.length > 1 ? args[1] : args[0]) : undefined;
        if (own) { const key = keyOf(message); if (key) channel.postMessage({ from: me, url: location.href, key, message }); }
        return send(...args);
      };
      keep(runtime0);
    } catch (e) {}
    channel.onmessage = (event) => {
      const d = event.data || {};
      if (d.from === me) return;
      if (d.storage) {
        // Several pages may offer the same change: it's delivered once, whoever brings it first.
        if (deliverStorage) deliverStorage(d.changes, d.area, d.area + '|' + d.key);
        return;
      }
      // The background is left to WebKit: it answers what pages ask it, and a relayed copy (which can't
      // be answered) arriving first would take the place of the real one.
      if (isWorker) return;
      if (!d.key || has(native, d.key)) { if (d.key) bump(native, d.key, -1); return; }
      bump(relayed, d.key, 1);
      const sender = { id: runtime0.id, url: d.url, origin: ownPlace.replace(/\/$/, '') };
      for (const fn of [...listeners.keys()]) {
        try { fn.call(null, d.message, sender, () => {}); } catch (e) { setTimeout(() => { throw e; }); }
      }
    };
    // Storage: each change seen by any context of the extension is offered to the others.
    const storageListeners = new Set(), storageSeen = new Map();
    let deliverStorage = null;
    // True when this change was already handed to the listeners in the last 5 s; marks it otherwise.
    const seenStorage = (key) => {
      const now = Date.now();
      for (const [k, at] of storageSeen) if (now - at > 5000) storageSeen.delete(k);
      if (storageSeen.has(key)) return true;
      storageSeen.set(key, now);
      return false;
    };
    const storage0 = globalThis.chrome.storage;
    if (storage0 && storage0.onChanged && typeof storage0.onChanged.addListener === 'function') {
      const sc = storage0.onChanged;
      const sAdd = sc.addListener.bind(sc);
      // One native listener hands each change to the extension's listeners once, and offers it to the
      // extension's other pages; a relayed copy that arrives first is delivered instead.
      deliverStorage = (changes, area, key) => {
        if (seenStorage(key)) return;
        for (const fn of [...storageListeners]) { try { fn(changes, area); } catch (e) { setTimeout(() => { throw e; }); } }
      };
      try {
        sc.addListener = function (fn) { if (typeof fn === 'function') storageListeners.add(fn); };
        sc.removeListener = function (fn) { storageListeners.delete(fn); };
        sc.hasListener = function (fn) { return storageListeners.has(fn); };
        sc.hasListeners = function () { return storageListeners.size > 0; };
        keep(sc);
      } catch (e) {}
      sAdd((changes, area) => {
        const key = area + '|' + keyOf(changes);
        deliverStorage(changes, area, key);
        try { channel.postMessage({ from: me, storage: true, area, key: keyOf(changes), changes }); } catch (e) {}
      });
    }
  }

  // fetch(…, { credentials: 'include' }) to a website goes through Browsa with that site's cookies
  // (ExtensionFetch.swift): WebKit sends none from an extension's origin, so Claude's panel was told
  // you weren't signed in to claude.ai. Streams (text/event-stream) and bodies Browsa can't carry are
  // left to WebKit. The idea is Search's (Office Commun, MIT).
  if (typeof globalThis.fetch === 'function' && typeof Response === 'function') {
    const nativeFetch = globalThis.fetch.bind(globalThis);
    const b64 = (buf) => { let s = ''; const u = new Uint8Array(buf); for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
    const unb64 = (s) => { const bin = atob(s || ''); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; };
    globalThis.fetch = async function (input, init) {
      try {
        const request = input instanceof Request ? input : null;
        const url = new URL(request ? request.url : String(input), location.href);
        const credentials = (init && init.credentials) || (request && request.credentials);
        const headers = new Headers((init && init.headers) || (request && request.headers) || undefined);
        const accept = headers.get('accept') || '';
        const body = init && init.body;
        const carried = body == null || typeof body === 'string' || body instanceof ArrayBuffer || ArrayBuffer.isView(body) || body instanceof URLSearchParams;
        if (credentials !== 'include' || !/^https?:$/.test(url.protocol) || accept.includes('text/event-stream') || !carried || (request && !init)) {
          return nativeFetch(input, init);
        }
        if (body instanceof URLSearchParams && !headers.has('content-type')) headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8');
        const encoded = body == null ? undefined : typeof body === 'string' || body instanceof URLSearchParams
          ? b64(new TextEncoder().encode(String(body))) : b64(body instanceof ArrayBuffer ? body : body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
        const signal = init && init.signal;
        if (signal && signal.aborted) throw new DOMException('The operation was aborted.', 'AbortError');
        const answer = await bridge('browsa.fetch', { url: url.href, method: (init && init.method) || 'GET', headers: Object.fromEntries(headers.entries()),
          body: encoded, redirect: (init && init.redirect) || 'follow', noStore: (init && init.cache) === 'no-store' });
        if (signal && signal.aborted) throw new DOMException('The operation was aborted.', 'AbortError');
        const response = new Response([101, 204, 205, 304].includes(answer.status) ? null : unb64(answer.body), { status: answer.status, headers: answer.headers });
        try { Object.defineProperty(response, 'url', { value: answer.url }); } catch (e) {}
        return response;
      } catch (e) {
        if (e && e.name === 'AbortError') throw e;
        throw new TypeError('Failed to fetch');
      }
    };
  }

  // Claude's side panel shows claude.ai/cic in a frame, signed in by claude.ai's SameSite=Lax cookies,
  // which WebKit doesn't send to a frame inside an extension's page: the frame stays empty. claude.ai
  // has its own answer for a panel it can't fill (cic_sidepanel_cowork_unavailable), and the panel
  // then shows its built-in chat on the extension's own sign-in. That message is given here as the
  // frame appears. From Search (Office Commun, MIT, SidePanel.swift PanelFrameFallback); drop once
  // WebKit sends those cookies.
  if (!isWorker && typeof MutationObserver === 'function' && globalThis.document) {
    const isClaudeFrame = (el) => {
      try { const u = new URL(el.src || '', location.href); return u.protocol === 'https:' && ['claude.ai', 'preview.claude.ai'].includes(u.hostname) && (u.pathname === '/cic' || u.pathname.startsWith('/cic/')); } catch (e) { return false; }
    };
    const told = new WeakSet();
    const check = (el) => {
      if (!el || el.tagName !== 'IFRAME' || told.has(el) || !isClaudeFrame(el)) return;
      told.add(el);
      setTimeout(() => window.dispatchEvent(new MessageEvent('message', { origin: 'https://claude.ai', data: { type: 'cic_sidepanel_cowork_unavailable' } })), 0);
    };
    const watch = () => new MutationObserver((records) => {
      for (const r of records) {
        if (r.type === 'attributes') check(r.target);
        for (const n of r.addedNodes || []) { check(n); if (n.querySelectorAll) n.querySelectorAll('iframe').forEach(check); }
      }
    }).observe(document.documentElement || document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch, { once: true });
  }

  if (!isWorker) return;

  // Native messaging ports, inside the worker. WebKit unloads a worker that hasn't posted on an open
  // port for two minutes, even with an app attached (1Password's helper, which then drops the
  // session). Browsa says {__browsaNative: 'alive'} every 25 s on each port to an app and the worker
  // answers 'beat'; neither word reaches the extension or the app (ExtensionNativeHosts.swift). The
  // idea is Search's (Office Commun, MIT, ExtensionShims.swift); the port handed to the extension is
  // a plain object, as WebKit's ports can't be proxied.
  for (const root of roots) {
    const runtime = root && root.runtime;
    const connectNative = runtime && runtime.connectNative;
    if (typeof connectNative !== 'function' || connectNative.__browsaBeat) continue;
    const ours = (m) => !!m && typeof m === 'object' && !Array.isArray(m) && '__browsaNative' in m;
    const beating = function (application) {
      const name = String(application);
      const port = connectNative.call(runtime, name);
      // Browsa's own in-process names know nothing of the beat.
      if (/^browsa\./.test(name)) return port;
      const fire = (set, ...args) => { for (const fn of [...set]) { try { fn(...args); } catch (e) { setTimeout(() => { throw e; }); } } };
      const listeners = () => {
        const set = new Set();
        return { set, event: {
          addListener(fn) { if (typeof fn === 'function') set.add(fn); },
          removeListener(fn) { set.delete(fn); },
          hasListener(fn) { return set.has(fn); },
          hasListeners() { return set.size > 0; },
        } };
      };
      const onMessage = listeners(), onDisconnect = listeners();
      let gone = false;
      const facade = keep({
        name,
        sender: undefined,
        onMessage: onMessage.event,
        onDisconnect: onDisconnect.event,
        postMessage(message) {
          if (gone) throw new Error('Attempting to use a disconnected port object');
          port.postMessage(message);
        },
        disconnect() { if (gone) return; gone = true; try { port.disconnect(); } catch (e) {} },
      });
      port.onMessage.addListener((m) => {
        if (ours(m)) {
          if (m.__browsaNative === 'alive') { try { port.postMessage({ __browsaNative: 'beat' }); } catch (e) {} }
          return;
        }
        fire(onMessage.set, m, facade);
      });
      port.onDisconnect.addListener(() => { if (gone) return; gone = true; fire(onDisconnect.set, facade); });
      return facade;
    };
    beating.__browsaBeat = true;
    keep(runtime);
    try { Object.defineProperty(runtime, 'connectNative', { value: beating, configurable: true, writable: true }); }
    catch (e) { try { runtime.connectNative = beating; } catch (e2) {} }
  }

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
