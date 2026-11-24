#if os(macOS)
import WebKit

/// How Browsa's page-world scripts (call audio, web notifications) reach Browsa without giving every
/// page `window.webkit.messageHandlers`. Safari never shows a page `window.webkit`, and sites read it as
/// an app's embedded web view rather than a browser: Google answers with CAPTCHAs and refuses
/// sign-ins as "not secure" (found by Search, Office Commun). So the handlers live in Browsa's own
/// world, and a relay there passes the page scripts' messages through `window.postMessage`.
///
/// A page script calls `__browsaBridge('name').postMessage(body)` (the helper `pageHelper` defines,
/// inside the script's own closure, not as a global) and gets the handler's reply as a promise.
enum PageBridge {
    @MainActor static let world = WKContentWorld.world(name: "BrowsaBridge")

    /// The relay, in Browsa's world: every frame, before the page's scripts.
    @MainActor static let relay = WKUserScript(source: #"""
    (() => {
      if (window.__browsaBridgeRelay) return;
      window.__browsaBridgeRelay = true;
      window.addEventListener('message', (e) => {
        const d = e.data;
        if (e.source !== window || !d || typeof d !== 'object' || typeof d.__browsaBridge !== 'string' || typeof d.id !== 'string') return;
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[d.__browsaBridge];
        const answer = (ok, value) => window.postMessage({ __browsaBridgeReply: d.id, ok, value }, '*');
        if (!h) return answer(false, 'unavailable');
        Promise.resolve().then(() => h.postMessage(d.body)).then((v) => answer(true, v), (err) => answer(false, String(err && err.message || err)));
      });
    })();
    """#, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    /// Put at the top of a page-world script: `__browsaBridge(name)` there gives an object with a
    /// promise-returning `postMessage`, as a WKScriptMessageHandlerWithReply has.
    static let pageHelper = #"""
    const __browsaBridge = (() => {
      const waiting = new Map();
      let next = 0;
      window.addEventListener('message', (e) => {
        const d = e.data;
        if (e.source !== window || !d || typeof d !== 'object' || typeof d.__browsaBridgeReply !== 'string') return;
        const w = waiting.get(d.__browsaBridgeReply);
        if (!w) return;
        waiting.delete(d.__browsaBridgeReply);
        d.ok ? w.resolve(d.value) : w.reject(new Error(d.value));
      });
      return (name) => ({
        postMessage(body) {
          const id = 'b' + Date.now().toString(36) + (next++) + Math.random().toString(36).slice(2, 8);
          return new Promise((resolve, reject) => {
            waiting.set(id, { resolve, reject });
            window.postMessage({ __browsaBridge: name, id, body }, '*');
          });
        }
      });
    })();
    """#
}
#endif
