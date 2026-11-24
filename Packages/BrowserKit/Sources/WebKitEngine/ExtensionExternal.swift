#if os(macOS)
import Foundation
import WebKit

/// A website talking to an extension that lists it under `externally_connectable`: claude.ai hands
/// Claude in Chrome its sign-in with chrome.runtime.sendMessage(extensionId, …). WebKit already
/// routes it (a `browser.runtime` in the page's world, delivered to runtime.onMessageExternal);
/// it just isn't named `chrome`. Only a page some loaded extension lists gets `chrome.runtime`, and
/// only if it has no `chrome` of its own, so other sites aren't told this is Chrome.
///
/// Ported from Search (Office Commun, MIT, ExtensionExternal.swift): the pattern rules and the page
/// script are theirs.
enum ExtensionExternal {
    nonisolated static func allowed(_ pattern: String) -> Bool {
        guard let start = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<start.lowerBound]
        guard ["*", "http", "https"].contains(scheme) else { return false }
        let rest = pattern[start.upperBound...]
        var host = String(rest.prefix { $0 != "/" }).lowercased()
        guard rest.dropFirst(host.count).hasPrefix("/") else { return false }
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        guard host != "*", !host.isEmpty else { return false }
        if host.hasPrefix("*.") {
            let base = host.dropFirst(2)
            guard base.contains("."), !base.contains("*") else { return false }
        } else if host.contains("*") {
            return false
        }
        let labels = host.split(separator: ".")
        return !labels.dropLast().contains("google")
    }

    /// For pages about to load, in their own world before any of their scripts; nil with nothing
    /// listed. `listings`: allowed patterns by the extension's runtime id.
    static func script(_ listings: [String: [String]]) -> WKUserScript? {
        let found = listings.compactMapValues { patterns -> [String]? in
            let kept = Array(Set(patterns.filter(allowed))).sorted()
            return kept.isEmpty ? nil : kept
        }
        guard !found.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: found, options: .sortedKeys),
              let list = String(data: data, encoding: .utf8) else { return nil }
        let source = """
        (function (listings) {
          var made = window.browser, runtime = made && made.runtime;
          if (typeof window.chrome !== 'undefined' || !runtime || typeof runtime.sendMessage !== 'function') return;
          // Chrome's match patterns: scheme, host, then path. A host with a
          // port matches that port only; one without, any.
          var glob = function (text) {
            return new RegExp('^' + text.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*') + '$');
          };
          var listed = function (pattern) {
            var parts = /^(\\*|https?):\\/\\/([^\\/]+)(\\/.*)$/.exec(pattern);
            if (!parts) return false;
            var scheme = location.protocol.slice(0, -1);
            if (parts[1] === '*' ? scheme !== 'http' && scheme !== 'https' : parts[1] !== scheme) return false;
            var host = parts[2], port = '';
            var colon = host.lastIndexOf(':');
            if (colon > 0 && host.indexOf(']') < colon) { port = host.slice(colon + 1); host = host.slice(0, colon); }
            if (port && port !== '*' && port !== location.port) return false;
            var here = location.hostname;
            if (host.indexOf('*.') === 0) {
              var base = host.slice(2);
              if (base.indexOf('.') < 0) return false;
              if (here !== base && here.slice(-base.length - 1) !== '.' + base) return false;
            } else if (host !== here) return false;
            return glob(parts[3]).test(location.pathname + location.search);
          };
          // The extensions that list this page: the only ones it can reach.
          var reached = Object.keys(listings).filter(function (id) { return listings[id].some(listed); });
          if (!reached.length) return;
          var chromeRuntime = {
            sendMessage: function (id, message, options, callback) {
              if (typeof options === 'function') { callback = options; options = undefined; }
              var sent = reached.indexOf(id) < 0
                ? Promise.reject(new Error('Could not establish connection. Receiving end does not exist.'))
                : options === undefined ? runtime.sendMessage(id, message) : runtime.sendMessage(id, message, options);
              if (typeof callback !== 'function') return sent;
              Promise.resolve(sent).then(function (reply) { callback(reply); }, function (error) {
                chromeRuntime.lastError = { message: String(error && error.message || error) };
                try { callback(); } finally { delete chromeRuntime.lastError; }
              });
            }
          };
          if (typeof runtime.connect === 'function') {
            chromeRuntime.connect = function () { return runtime.connect.apply(runtime, arguments); };
          }
          try {
            Object.defineProperty(window, 'chrome', {
              value: { runtime: chromeRuntime }, configurable: true, writable: true, enumerable: false
            });
          } catch (e) {}
        })(\(list));
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
}
#endif
