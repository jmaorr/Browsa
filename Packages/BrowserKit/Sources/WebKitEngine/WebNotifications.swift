#if os(macOS)
import Foundation
import WebKit
import BrowserEngine

/// Web notifications (`new Notification(…)`, `Notification.requestPermission()`, a service worker
/// registration's `showNotification`) as macOS notifications.
///
/// WKWebView on the Mac has no public way to show a site's notifications, so pages get Browsa's own
/// `Notification` in their world. It asks the app (per site, like camera and microphone) and hands each
/// notification to the page's delegate, which posts it. Clicking one brings its tab forward and fires
/// the page's `click` event.
///
/// Sites can only ask after a click or key press, as in Safari, so pages can't prompt on load.
/// Private tabs are always told no. Notifications only show while the site is open in a tab: there is
/// no push to a closed tab.
enum WebNotifications {
    static let messageName = "browsaNotifications"
    /// Called from native with (id, type) to fire a notification's `click` or `close` event.
    static let eventFunction = "__browsaNotificationEvent"

    /// The page-world script. `saved` is each site's saved answer, so `Notification.permission` is right from
    /// the first line of the page's own scripts.
    static func script(saved: [String: Bool]) -> WKUserScript {
        let json = (try? JSONSerialization.data(withJSONObject: saved)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let source = shim.replacingOccurrences(of: "__SAVED__", with: json)
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// Answers the page-world script.
    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        private let page: @MainActor (WKWebView) -> WebKitPage?
        private let saved: @MainActor () -> [String: Bool]

        init(page: @escaping @MainActor (WKWebView) -> WebKitPage?, saved: @escaping @MainActor () -> [String: Bool]) {
            self.page = page
            self.saved = saved
        }

        @MainActor
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            let body = message.body as? [String: Any] ?? [:]
            guard message.frameInfo.isMainFrame, let webView = message.webView, let page = page(webView) else {
                return replyHandler("denied", nil)
            }
            let host = message.frameInfo.securityOrigin.host
            let isPrivate = page.profile == .ephemeral
            func state() -> String {
                if isPrivate { return "denied" }
                return saved()[host].map { $0 ? "granted" : "denied" } ?? "default"
            }
            switch body["type"] as? String {
            case "state":
                replyHandler(state(), nil)
            case "request":
                let current = state()
                // Only a click or key press can bring up the question, as in Safari.
                guard current == "default", body["activated"] as? Bool == true, let delegate = page.delegate else {
                    return replyHandler(current, nil)
                }
                Task { @MainActor in
                    let granted = await delegate.page(page, requestPermission: .notifications, host: host)
                    replyHandler(granted ? "granted" : "denied", nil)
                }
            case "show":
                guard state() == "granted", let delegate = page.delegate,
                      let id = (body["id"] as? String).flatMap(Self.cleanID) else { return replyHandler(false, nil) }
                let icon = (body["icon"] as? String).flatMap(URL.init(string:)).flatMap { ["https", "http", "data"].contains($0.scheme ?? "") ? $0 : nil }
                let notification = WebNotification(
                    id: id,
                    title: String((body["title"] as? String ?? "").prefix(200)),
                    body: String((body["body"] as? String ?? "").prefix(1000)),
                    host: host,
                    tag: (body["tag"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                    icon: icon,
                    silent: body["silent"] as? Bool ?? false)
                delegate.page(page, showNotification: notification)
                replyHandler(true, nil)
            case "close":
                if let id = (body["id"] as? String).flatMap(Self.cleanID) {
                    page.delegate?.page(page, closeNotification: id, tag: (body["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                }
                replyHandler(nil, nil)
            default:
                replyHandler(nil, "Unknown message")
            }
        }

        /// Ids come from the script: letters and digits only.
        static func cleanID(_ id: String) -> String? {
            id.count <= 64 && !id.isEmpty && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? id : nil
        }
    }

    private static let shim = #"""
    (function () {
      if (window.top !== window || !window.isSecureContext) return;
      function bridge() {
        var handlers = window.webkit && window.webkit.messageHandlers;
        return handlers && handlers.browsaNotifications;
      }
      if (!bridge()) return;
      // Looked up each time: the app can swap the handler while the page is open, and an old one goes dead.
      function post(m) {
        var h = bridge();
        return h ? h.postMessage(m) : Promise.reject(new Error('Notifications unavailable'));
      }
      var saved = __SAVED__;
      var host = location.hostname;
      var permission = Object.prototype.hasOwnProperty.call(saved, host) ? (saved[host] ? 'granted' : 'denied') : 'default';
      var live = new Map();
      var store = new WeakMap();
      var watchers = [];

      function setPermission(p) {
        if (p !== 'granted' && p !== 'denied' && p !== 'default') return;
        if (p === permission) return;
        permission = p;
        watchers.forEach(function (w) { try { w(); } catch (e) {} });
      }
      post({ type: 'state' }).then(setPermission, function () {});

      function uid() { return 'n' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10); }
      function abs(u) { try { return u ? new URL(String(u), location.href).href : ''; } catch (e) { return ''; } }
      function activated() { var a = navigator.userActivation; return !a || !!a.isActive; }
      function fire(n, type) {
        var e = new Event(type, { cancelable: type === 'click' });
        n.dispatchEvent(e);
        var on = store.get(n).handlers[type];
        if (typeof on === 'function') { try { on.call(n, e); } catch (err) { setTimeout(function () { throw err; }); } }
      }
      function payload(id, title, o) {
        return { type: 'show', id: id, title: String(title), body: o.body == null ? '' : String(o.body),
                 tag: o.tag == null ? '' : String(o.tag), icon: abs(o.icon), silent: !!o.silent };
      }

      class Notification extends EventTarget {
        constructor(title, options) {
          super();
          if (arguments.length < 1) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          var o = options || {};
          var id = uid();
          var d = {
            id: id, title: String(title), body: o.body == null ? '' : String(o.body), tag: o.tag == null ? '' : String(o.tag),
            icon: abs(o.icon), image: abs(o.image), badge: abs(o.badge), data: o.data === undefined ? null : o.data,
            dir: o.dir || 'auto', lang: o.lang || '', silent: o.silent == null ? null : !!o.silent,
            requireInteraction: !!o.requireInteraction, renotify: !!o.renotify, timestamp: o.timestamp || Date.now(),
            actions: [], handlers: {}, closed: false
          };
          store.set(this, d);
          var self = this;
          if (permission !== 'granted') { setTimeout(function () { fire(self, 'error'); }); return; }
          if (d.tag) live.forEach(function (n, key) { if (store.get(n).tag === d.tag) live.delete(key); });
          live.set(id, this);
          post(payload(id, title, o)).then(function (ok) {
            if (ok) { fire(self, 'show'); } else { live.delete(id); fire(self, 'error'); }
          }, function () { live.delete(id); fire(self, 'error'); });
        }
        static get permission() { return permission; }
        static get maxActions() { return 2; }
        static requestPermission(callback) {
          var p = permission !== 'default' ? Promise.resolve(permission)
            : post({ type: 'request', activated: activated() }).then(function (r) { setPermission(r); return permission; },
                                                                      function () { return permission; });
          return p.then(function (r) { if (typeof callback === 'function') { try { callback(r); } catch (e) {} } return r; });
        }
        close() {
          var d = store.get(this);
          if (!d || d.closed) return;
          d.closed = true;
          live.delete(d.id);
          post({ type: 'close', id: d.id, tag: d.tag }).catch(function () {});
          var self = this;
          setTimeout(function () { fire(self, 'close'); });
        }
      }
      ['title', 'body', 'tag', 'icon', 'image', 'badge', 'data', 'dir', 'lang', 'silent', 'requireInteraction',
       'renotify', 'timestamp', 'actions'].forEach(function (k) {
        Object.defineProperty(Notification.prototype, k, { get: function () { return store.get(this)[k]; }, configurable: true, enumerable: true });
      });
      ['click', 'show', 'error', 'close'].forEach(function (t) {
        Object.defineProperty(Notification.prototype, 'on' + t, {
          get: function () { return store.get(this).handlers[t] || null; },
          set: function (f) { store.get(this).handlers[t] = typeof f === 'function' ? f : null; },
          configurable: true, enumerable: true
        });
      });
      Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true, enumerable: false });

      Object.defineProperty(window, '__browsaNotificationEvent', {
        value: function (id, type) {
          var n = live.get(id);
          if (!n) return;
          if (type === 'click') fire(n, 'click');
          var d = store.get(n);
          if (!d.closed) { d.closed = true; live.delete(id); fire(n, 'close'); }
        },
        writable: false, configurable: false, enumerable: false
      });

      // Sites that show notifications through their service worker registration (Slack, Teams, Discord, …).
      if (window.ServiceWorkerRegistration) {
        Object.defineProperty(ServiceWorkerRegistration.prototype, 'showNotification', {
          value: function (title, options) {
            if (permission !== 'granted') return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
            return post(payload(uid(), title, options || {})).then(function () {});
          },
          writable: true, configurable: true
        });
        Object.defineProperty(ServiceWorkerRegistration.prototype, 'getNotifications', {
          value: function () { return Promise.resolve([]); }, writable: true, configurable: true
        });
      }

      // navigator.permissions.query({ name: 'notifications' }) agrees with Notification.permission.
      var perms = navigator.permissions;
      if (perms && perms.query) {
        var query = perms.query.bind(perms);
        perms.query = function (d) {
          if (!d || d.name !== 'notifications') return query.apply(null, arguments);
          var status = new EventTarget();
          var state = function () { return permission === 'default' ? 'prompt' : permission; };
          var onchange = null;
          Object.defineProperties(status, {
            name: { value: 'notifications', enumerable: true },
            state: { get: state, enumerable: true },
            onchange: { get: function () { return onchange; }, set: function (f) { onchange = typeof f === 'function' ? f : null; }, enumerable: true }
          });
          watchers.push(function () {
            var e = new Event('change');
            status.dispatchEvent(e);
            if (onchange) onchange.call(status, e);
          });
          return Promise.resolve(status);
        };
      }
    })();
    """#
}
#endif
