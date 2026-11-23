import Foundation

/// Site Styles: optional new looks for particular sites, which you turn on yourself, site by site. They only
/// change how a site looks (layout, spacing, hiding clutter), never what it does. Unlike Site Optimisations,
/// which fix a site quietly for everyone, these are off until you choose them.
public struct SiteStyle: Identifiable, Sendable, Equatable {
    public let id: String
    /// The site, as people know it: "LinkedIn".
    public let site: String
    /// What turning it on gives you, in a few words: "Tidy feed".
    public let name: String
    /// One plain sentence for the suggestion and Settings.
    public let summary: String
    /// Runs on these hosts and their subdomains.
    public let hosts: [String]
    let css: String
    /// Marks things CSS can't find on its own. Runs once, after the stylesheet.
    let helper: String

    public func matches(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Adds the stylesheet, or turns it back on if this page already has it. Keeps it in the page if the
    /// site's own code removes it.
    public var enableSource: String {
        let literal = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function () {
          var id = 'browsa-style-\(id)', style = document.getElementById(id);
          if (style) { style.disabled = false; return; }
          style = document.createElement('style');
          style.id = id; style.textContent = \(literal);
          (document.head || document.documentElement).appendChild(style);
          new MutationObserver(function () {
            if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
          }).observe(document.documentElement, { childList: true });
          try {
        \(helper)
          } catch (e) {}
        })();
        """
    }

    /// Turns the stylesheet off on a page that has it, without a reload.
    public var disableSource: String {
        "(function () { var s = document.getElementById('browsa-style-\(id)'); if (s) s.disabled = true; })();"
    }

    /// The styles that can run on `url`.
    public static func available(for url: URL?) -> [SiteStyle] { all.filter { $0.matches(url) } }

    public static let all: [SiteStyle] = [linkedInTidy]

    /// LinkedIn: a calmer, roomier home feed. Drops the right-hand column (news, puzzles, ads) so the feed can be
    /// about 40% wider, softens the cards, sets post text a little larger, and hides promoted posts.
    ///
    /// LinkedIn's class names are generated and change often, so this only hooks onto things that are steadier:
    /// landmark labels ("Sidebar", "Primary content", "Aside"), test ids ("mainFeed", "expandable-text-box"), list
    /// roles and post keys ("update-card-focus…", so rows like "Sort by" keep their look). The layout changes apply on
    /// pages built from LinkedIn's three columns (the feed, a single post, and others), and leave other layouts alone.
    public static let linkedInTidy = SiteStyle(
        id: "linkedin-tidy",
        site: "LinkedIn",
        name: "Tidy Feed",
        summary: "A wider feed without the side column, softer cards and no promoted posts.",
        hosts: ["linkedin.com"],
        css: #"""
        main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) aside[aria-label="Aside"] { display: none !important; }
        main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) :has(> aside[aria-label="Sidebar"]) {
          display: grid !important; grid-template-columns: 232px minmax(0, 1fr) !important; column-gap: 32px !important;
          max-width: 1060px !important; width: 100% !important; margin-inline: auto !important;
        }
        main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) :has(> aside[aria-label="Sidebar"]) > * {
          grid-column: auto !important; width: auto !important; max-width: none !important; min-width: 0 !important;
        }
        main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) aside[aria-label="Sidebar"] { width: 232px !important; }
        @media (max-width: 900px) {
          main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) aside[aria-label="Sidebar"] { display: none !important; }
          main#workspace:has(aside[aria-label="Sidebar"]):has(section[aria-label="Primary content"]) :has(> aside[aria-label="Sidebar"]) {
            grid-template-columns: minmax(0, 1fr) !important; max-width: 720px !important;
          }
        }
        main#workspace [data-testid="mainFeed"] [role="listitem"][componentkey^="update-card-focus"],
        main#workspace [data-testid="mainFeed"] [role="listitem"]:has([componentkey="shareboxProfilePictureComponentRef"]),
        main#workspace [componentkey="feed-tab-host_tab-bar"],
        main#workspace [data-browsa-card] {
          border-radius: 14px !important; overflow: hidden;
          box-shadow: 0 0 0 1px rgba(127, 127, 127, .14), 0 1px 3px rgba(0, 0, 0, .04) !important;
        }
        main#workspace [data-testid="mainFeed"] [role="listitem"][componentkey^="update-card-focus"] { margin-bottom: 6px !important; }
        main#workspace [data-testid="expandable-text-box"] { font-size: 15px !important; line-height: 1.55 !important; }
        [data-browsa-promoted] { display: none !important; }
        """#,
        // Promoted posts are only marked by their "Promoted" label, and the sidebar's cards are plain divs: mark
        // them with attributes the stylesheet hides or rounds.
        helper: #"""
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
        if (document.body) mark();
        new MutationObserver(function () {
          if (!pending) pending = setTimeout(mark, 150);
        }).observe(document, { childList: true, subtree: true });
        """#)
}
