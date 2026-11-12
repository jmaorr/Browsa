#if os(macOS)
import WebKit

/// Tells the app when a page is playing sound or holds text someone typed, so a busy tab isn't
/// unloaded to save memory. One small script per frame, in its own world, out of the page's reach.
/// Each frame reports only when its answer changes.
enum PageActivity {
    @MainActor static let world = WKContentWorld.world(name: "browsa.activity")
    static let messageName = "browsaActivity"

    /// One frame's state. `frame` is a token the frame's script made up, unique per document.
    struct Report: Sendable {
        let frame: String
        let audible: Bool
        let typed: Bool
    }

    @MainActor static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        private let onReport: @MainActor (WKWebView, Report) -> Void

        init(onReport: @escaping @MainActor (WKWebView, Report) -> Void) {
            self.onReport = onReport
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
                  frame.count <= 32, let webView = message.webView else { return }
            let report = Report(frame: frame, audible: body["audible"] as? Bool ?? false, typed: body["typed"] as? Bool ?? false)
            MainActor.assumeIsolated { onReport(webView, report) }
        }
    }

    /// Sound: any audio or video element playing, not muted, with volume up. Typing: a text field,
    /// text area or editable area the person typed into (not a script) that still holds text. A
    /// submitted form's fields stop counting. Fields emptied by a script (a chat sending a message)
    /// are noticed by a slow re-check that only runs while something is typed.
    private static let source = """
    (function () {
      if (window.__browsaActivity) return;
      window.__browsaActivity = true;
      var frame = Math.random().toString(36).slice(2, 14);
      var media = new Set(), fields = new Set(), last = '', recheck = 0;

      function audible() {
        document.querySelectorAll('audio, video').forEach(function (m) { media.add(m); });
        var on = false;
        media.forEach(function (m) {
          if (!m.isConnected && m.paused) { media.delete(m); return; }
          if (!m.paused && !m.ended && !m.muted && m.volume > 0) on = true;
        });
        return on;
      }
      function text(f) { return f.isContentEditable ? f.textContent : f.value; }
      function typed() {
        fields.forEach(function (f) { var v = text(f); if (!f.isConnected || !v || !v.trim()) fields.delete(f); });
        return fields.size > 0;
      }
      function post(a, t) {
        try { webkit.messageHandlers.\(messageName).postMessage({ frame: frame, audible: a, typed: t }); } catch (e) {}
      }
      function report() {
        var a = audible(), t = typed(), now = (a ? 'a' : '') + (t ? 't' : '');
        if (t && !recheck) recheck = setInterval(report, 10000);
        if (!t && recheck) { clearInterval(recheck); recheck = 0; }
        if (now === last) return;
        last = now;
        post(a, t);
      }
      function editable(el) {
        if (!el) return false;
        if (el.isContentEditable) return true;
        if (el instanceof HTMLTextAreaElement) return true;
        if (el instanceof HTMLInputElement)
          return !/^(search|checkbox|radio|range|color|file|submit|button|reset|image|hidden)$/i.test(el.type);
        return false;
      }

      ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          if (e.target instanceof HTMLMediaElement) media.add(e.target);
          report();
        }, true);
      });
      document.addEventListener('input', function (e) {
        if (!e.isTrusted) return;
        var el = e.target && e.target.isContentEditable ? e.target.closest('[contenteditable]') || e.target : e.target;
        if (!editable(el)) return;
        fields.add(el);
        report();
      }, true);
      document.addEventListener('submit', function (e) {
        fields.forEach(function (f) { if (e.target.contains(f)) fields.delete(f); });
        report();
      }, true);
      window.addEventListener('pagehide', function () { last = ''; post(false, false); });
      window.addEventListener('pageshow', function (e) { if (e.persisted) { last = '-'; report(); } });
    })();
    """
}
#endif
