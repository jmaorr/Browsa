const api = globalThis.browser ?? globalThis.chrome;
let installed = false;
api.runtime.onInstalled?.addListener(() => { installed = true; });
async function attempt(fn) {
  try { return { ok: await fn() }; } catch (error) { return { error: String(error) }; }
}
api.runtime.onMessage.addListener((message, sender, reply) => {
  (async () => { try {
    const present = {};
    for (const name of ["storage", "tabs", "scripting", "cookies", "alarms", "webNavigation", "declarativeNetRequest", "contextMenus", "menus", "action", "webRequest", "identity", "offscreen", "sidePanel", "tabGroups", "history", "bookmarks", "downloads", "notifications", "debugger", "proxy", "management", "privacy", "nativeMessaging"]) {
      present[name] = api[name] !== undefined;
    }
    reply({
      serviceWorker: typeof ServiceWorkerGlobalScope !== "undefined" && self instanceof ServiceWorkerGlobalScope,
      chromeNamespace: globalThis.chrome !== undefined,
      browserNamespace: globalThis.browser !== undefined,
      onInstalledFired: installed,
      senderTab: sender.tab?.url ?? null,
      storage: await attempt(async () => { await api.storage.local.set({ a: 1 }); return (await api.storage.local.get("a")).a; }),
      tabsQuery: await attempt(async () => (await api.tabs.query({ active: true })).map((t) => t.url)),
      scripting: await attempt(async () => (await api.scripting.executeScript({ target: { tabId: sender.tab.id }, func: () => document.title }))[0].result),
      cookies: await attempt(async () => (await api.cookies.getAll({ url: sender.tab.url })).length),
      alarms: await attempt(async () => { await api.alarms.create("x", { delayInMinutes: 1 }); return (await api.alarms.getAll()).length; }),
      nativeMessaging: typeof api.runtime.sendNativeMessage,
      present,
    });
  } catch (error) { reply({ fatal: String(error), stack: error.stack }); } })();
  return true;
});
