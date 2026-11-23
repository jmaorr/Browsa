#if canImport(WebKit)
import Foundation
import WebKit

/// Site Optimisations: small, site-specific fixes for pages that run badly in WebKit but fine in Chromium, the
/// way Safari quietly carries its own per-site quirks. Each one runs only on the sites it names, in the page's
/// own world, and is meant to leave the site working exactly as before, only faster.
///
/// Set `siteOptimisations` to false in the defaults to turn them all off.
enum SiteOptimisations {
    struct Fix {
        /// What it fixes, for logs and a future Settings list.
        let name: String
        /// Runs on these hosts and their subdomains.
        let hosts: [String]
        let source: String
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "siteOptimisations") as? Bool ?? true
    }

    static let all: [Fix] = [elevenLabsDictationCursor]

    /// One script for every fix, each gated on its hosts. Main frames only: none of the fixes are for iframes.
    static var script: WKUserScript? {
        guard isEnabled, !all.isEmpty else { return nil }
        let body = all.map { fix -> String in
            let hosts = (try? JSONEncoder().encode(fix.hosts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            // \(fix.name)
            if (\(hosts).some(function (d) { return h === d || h.endsWith('.' + d); })) {
              try { \(fix.source) } catch (e) {}
            }
            """
        }.joined(separator: "\n")
        let source = "(function () {\n  var h = location.hostname;\n\(body)\n})();"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// ElevenLabs: typing in a text box (the sound effects search, for one) ran at about 5 frames a second.
    /// Their dictation cursor finds the caret on every keystroke by adding a hidden copy of the text box straight
    /// to `<body>`, measuring it and taking it away again. Changing `<body>`'s children makes WebKit restyle the
    /// whole page each time (Chromium only restyles what changed), about 90ms on their pages. This keeps that copy
    /// in one hidden holder that stays in `<body>`, so `<body>`'s children never change. The measurements only use
    /// distances within the copy, so they come out the same.
    static let elevenLabsDictationCursor = Fix(name: "ElevenLabs typing", hosts: ["elevenlabs.io"], source: #"""
    var append = Node.prototype.appendChild, remove = Node.prototype.removeChild, holder = null, held = new WeakSet();
    function isMirror(n) {
      if (!(n instanceof HTMLDivElement) || n.firstChild || n.attributes.length !== 1) return false;
      var s = n.style;
      return s.position === 'absolute' && s.visibility === 'hidden' && s.pointerEvents === 'none' &&
        s.left === '0px' && s.top === '0px' && s.boxSizing === 'border-box';
    }
    function home() {
      if (!holder) {
        holder = document.createElement('div');
        holder.setAttribute('aria-hidden', 'true');
        holder.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;overflow:visible;visibility:hidden;' +
          'pointer-events:none;contain:layout style;';
      }
      if (holder.parentNode !== document.body) append.call(document.body, holder);
      return holder;
    }
    Node.prototype.appendChild = function (n) {
      if (this === document.body && isMirror(n)) { held.add(n); return append.call(home(), n); }
      return append.call(this, n);
    };
    Node.prototype.removeChild = function (n) {
      if (this === document.body && held.has(n) && holder && n.parentNode === holder) { held.delete(n); return remove.call(holder, n); }
      return remove.call(this, n);
    };
    """#)
}
#endif
