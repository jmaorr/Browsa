#if canImport(WebKit)
import Foundation
import WebKit

/// Site Optimisations: small, site-specific fixes for pages that run badly in WebKit but fine in Chromium, the
/// way Safari quietly carries its own per-site quirks. Each one runs only on the sites it names, in the page's
/// own world, and is meant to leave the site working exactly as before, only faster.
///
/// Set `siteOptimisations` to false in the defaults to turn them all off. Style-only fixes (like LinkedIn's) can
/// also be turned off on their own with `siteOptimisations.styles`.
enum SiteOptimisations {
    struct Fix {
        /// What it fixes, for logs and a future Settings list.
        let name: String
        /// Runs on these hosts and their subdomains.
        let hosts: [String]
        let source: String
        /// Only changes how the site looks (layout, spacing, hiding clutter), never what it does.
        var isStyle = false
    }

    /// Adds `css` to the page as early as possible and keeps it there. Goes on `<html>` because `<head>` doesn't
    /// exist yet at document start; a `<style>` there still applies.
    static func stylesheet(id: String, _ css: String) -> String {
        let literal = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        var css = \(literal), style = document.createElement('style');
        style.id = '\(id)'; style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
        new MutationObserver(function () {
          if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
        }).observe(document.documentElement, { childList: true });
        """
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "siteOptimisations") as? Bool ?? true
    }

    static var stylesEnabled: Bool {
        UserDefaults.standard.object(forKey: "siteOptimisations.styles") as? Bool ?? true
    }

    static let all: [Fix] = [elevenLabsDictationCursor, linkedInTidy]

    /// One script for every fix, each gated on its hosts. Main frames only: none of the fixes are for iframes.
    static var script: WKUserScript? {
        let fixes = all.filter { !$0.isStyle || stylesEnabled }
        guard isEnabled, !fixes.isEmpty else { return nil }
        let body = fixes.map { fix -> String in
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
    /// LinkedIn: a calmer, roomier home feed. Drops the right-hand column (news, puzzles, ads) and lets the feed
    /// fill the rest of the window beside the profile sidebar, keeps photos and videos within the screen, softens the cards, sets post text a little larger, and hides promoted posts. Nothing about
    /// how the site works changes. LinkedIn's class names are generated and change often, so this only hooks onto
    /// things that are steadier: landmark labels ("Sidebar", "Primary content", "Aside"), test ids ("mainFeed",
    /// "expandable-text-box") and list roles. The layout changes only apply on pages that have the main feed.
    static let linkedInTidy = Fix(name: "LinkedIn tidy feed", hosts: ["linkedin.com"], source: stylesheet(id: "browsa-linkedin", #"""
    main#workspace:has([data-testid="mainFeed"]) aside[aria-label="Aside"] { display: none !important; }
    main#workspace:has([data-testid="mainFeed"]) > div:has(aside[aria-label="Sidebar"]) {
      max-width: none !important; width: 100% !important; margin-inline: 0 !important;
    }
    main#workspace:has([data-testid="mainFeed"]) :has(> aside[aria-label="Sidebar"]) {
      display: grid !important; grid-template-columns: 232px minmax(0, 1fr) !important; column-gap: 24px !important;
      max-width: none !important; width: 100% !important; margin-inline: 0 !important;
      padding-inline: 24px !important; box-sizing: border-box !important;
    }
    main#workspace:has([data-testid="mainFeed"]) :has(> aside[aria-label="Sidebar"]) > * {
      grid-column: auto !important; width: auto !important; max-width: none !important; min-width: 0 !important;
    }
    main#workspace:has([data-testid="mainFeed"]) aside[aria-label="Sidebar"] { width: 232px !important; }
    @media (max-width: 900px) {
      main#workspace:has([data-testid="mainFeed"]) aside[aria-label="Sidebar"] { display: none !important; }
      main#workspace:has([data-testid="mainFeed"]) :has(> aside[aria-label="Sidebar"]) {
        grid-template-columns: minmax(0, 1fr) !important;
      }
    }
    main#workspace section[aria-label="Primary content"] [role="listitem"],
    main#workspace [componentkey="feed-tab-host_tab-bar"],
    main#workspace [data-browsa-card] {
      border-radius: 14px !important; overflow: hidden;
      box-shadow: 0 0 0 1px rgba(127, 127, 127, .14), 0 1px 3px rgba(0, 0, 0, .04) !important;
    }
    main#workspace [data-testid="mainFeed"] [role="listitem"] { margin-bottom: 6px !important; }
    main#workspace [data-testid="expandable-text-box"] { font-size: 15px !important; line-height: 1.55 !important; }
    [data-browsa-promoted] { display: none !important; }
    /* With the feed this wide, a photo would fill the screen: keep media within about three quarters of it. */
    main#workspace [data-testid="mainFeed"] [style*="aspect-ratio"] { max-height: 72vh !important; aspect-ratio: auto !important; }
    main#workspace [data-testid="mainFeed"] figure[style*="aspect-ratio"] { background: rgba(127, 127, 127, .08) !important; }
    main#workspace [data-testid="mainFeed"] [style*="aspect-ratio"] img {
      max-height: 72vh !important; width: 100% !important; height: 100% !important; object-fit: contain !important;
    }
    main#workspace [data-testid="mainFeed"] video { max-height: 72vh !important; object-fit: contain !important; }
    """#) + #"""

    // Two things CSS can't find on its own: promoted posts (only their "Promoted" label marks them) and the
    // sidebar's cards (plain divs). Mark them with attributes the stylesheet above hides or rounds.
    var pending = 0;
    function mark() {
      pending = 0;
      var cards = document.querySelectorAll('[data-testid="mainFeed"] [role="listitem"]:not([data-browsa-seen])');
      for (var i = 0; i < cards.length; i++) {
        var card = cards[i];
        if (!card.querySelector('button[aria-label^="Open control menu"]')) continue; // not drawn yet
        card.setAttribute('data-browsa-seen', '');
        var labels = card.querySelectorAll('p, span');
        for (var j = 0; j < labels.length; j++) {
          if (!labels[j].firstElementChild && labels[j].textContent.trim() === 'Promoted') {
            card.setAttribute('data-browsa-promoted', ''); break;
          }
        }
      }
      var side = document.querySelector('main#workspace aside[aria-label="Sidebar"]');
      if (side && !side.querySelector('[data-browsa-card]')) {
        var boxes = side.querySelectorAll('div');
        for (var k = 0; k < boxes.length; k++) {
          var s = getComputedStyle(boxes[k]);
          if (boxes[k].offsetWidth > 150 && s.borderRadius === '8px' && s.boxShadow !== 'none') {
            boxes[k].setAttribute('data-browsa-card', '');
          }
        }
      }
    }
    new MutationObserver(function () {
      if (!pending) pending = setTimeout(mark, 150);
    }).observe(document, { childList: true, subtree: true });
    """#, isStyle: true)
}
#endif
