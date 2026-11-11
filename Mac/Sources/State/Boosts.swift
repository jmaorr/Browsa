import Foundation
import Observation
import BrowserCore
import BrowserEngine

/// Boosts: your own look for a site, like Arc's. Each one is a few easy choices (font, colour,
/// elements zapped away) plus optional CSS and a script, stored on this Mac and never sent anywhere.
///
/// The engine runs them (`BrowserEngine.applyBoosts`): styles go in before the page draws, scripts
/// after it loads, both in their own world so a Boost never sees the page's JavaScript.
struct SiteBoost: Codable, Identifiable, Equatable {
    enum Font: String, Codable, CaseIterable, Identifiable {
        case site, system, serif, rounded, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .site: "Site"
            case .system: "System"
            case .serif: "Serif"
            case .rounded: "Rounded"
            case .mono: "Mono"
            }
        }
        var family: String? {
            switch self {
            case .site: nil
            case .system: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            case .serif: "'New York', ui-serif, Georgia, serif"
            case .rounded: "ui-rounded, 'SF Pro Rounded', -apple-system, sans-serif"
            case .mono: "ui-monospace, 'SF Mono', Menlo, monospace"
            }
        }
    }

    var id = UUID()
    /// "github.com" also covers its subdomains.
    var host: String
    var isOn = true
    var font: Font = .site
    /// Degrees to turn the site's colours round the colour wheel. Pictures and video keep theirs.
    var hue: Double = 0
    /// Elements picked with Zap, hidden on every visit.
    var zaps: [Zap] = []
    var css = ""
    var script = ""
    var created = Date()

    struct Zap: Codable, Equatable, Identifiable {
        var id = UUID()
        var selector: String
        /// What it was, in a few words, for the list ("div · Recommended for you").
        var label: String
    }

    init(host: String) { self.host = host }

    /// Everything the choices add up to, as one style sheet.
    var effectiveCSS: String {
        var parts: [String] = []
        if let family = font.family {
            parts.append(":where(body, p, li, h1, h2, h3, h4, h5, h6, a, td, th, dd, dt, blockquote, input, textarea, button, label, figcaption) { font-family: \(family) !important; }")
        }
        if hue != 0 {
            let deg = Int(hue.rounded())
            parts.append("html { filter: hue-rotate(\(deg)deg) !important; }")
            parts.append("img, video, picture, canvas, iframe, svg image, [style*='background-image'] { filter: hue-rotate(\(-deg)deg) !important; }")
        }
        if !zaps.isEmpty {
            parts.append(zaps.map(\.selector).joined(separator: ",\n") + " { display: none !important; }")
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(css) }
        return parts.joined(separator: "\n")
    }

    var isEmpty: Bool { font == .site && hue == 0 && zaps.isEmpty && css.isEmpty && script.isEmpty }

    /// The part of the address a Boost is keyed by: the host without "www.".
    static func key(for url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func matches(_ host: String) -> Bool { host == self.host || host.hasSuffix("." + self.host) }
}

@MainActor @Observable
final class BoostStore {
    static let shared = BoostStore()

    private(set) var boosts: [SiteBoost] = []
    @ObservationIgnored private weak var engine: (any BrowserEngine)?
    @ObservationIgnored private let fileURL = AppFolders.support.appending(path: "Browser/boosts.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([SiteBoost].self, from: data) {
            boosts = saved
        }
    }

    /// Called once the engine exists. Pages loaded from now on get every Boost that's on.
    func attach(engine: any BrowserEngine) {
        self.engine = engine
        push()
    }

    func boost(for url: URL?) -> SiteBoost? {
        guard let key = SiteBoost.key(for: url) else { return nil }
        return boosts.first { $0.host == key } ?? boosts.first { $0.matches(key) }
    }

    /// The Boost for this site, made if there isn't one yet.
    func boostOrNew(for url: URL?) -> SiteBoost? {
        if let b = boost(for: url) { return b }
        guard let key = SiteBoost.key(for: url) else { return nil }
        return SiteBoost(host: key)
    }

    func save(_ boost: SiteBoost) {
        if let i = boosts.firstIndex(where: { $0.id == boost.id }) {
            boosts[i] = boost
        } else if !boost.isEmpty {
            boosts.append(boost)
        }
        changed()
    }

    func remove(_ id: UUID) {
        boosts.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        push()
        saveTask?.cancel()
        let snapshot = boosts, url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(snapshot).write(to: url, options: .atomic)
        }
    }

    private func push() {
        engine?.applyBoosts(boosts.filter(\.isOn).map { PageBoost(host: $0.host, css: $0.effectiveCSS, script: $0.script) })
    }

    /// Shows a Boost's style on a page now, without reloading. Its script runs on the next load.
    func preview(_ boost: SiteBoost?, on page: any EnginePage) async {
        let css = boost.map { $0.isOn ? $0.effectiveCSS : "" } ?? ""
        let body = PageBoost.applyCSSFunction + "\n__browsaBoostCSS(\(Self.jsString(css))); return true;"
        _ = try? await page.evaluate(body, inWorld: PageBoost.world)
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Zap: point at something on the page and click to hide it. Esc cancels.
enum ZapPicker {
    /// Resolves with `{ selector, label }` once something is clicked, or null on Esc.
    static let script = """
    return await new Promise((resolve) => {
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b30;background:rgba(255,59,48,.12);border-radius:4px;transition:all .06s ease-out;';
      const tip = document.createElement('div');
      tip.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;font:600 11px -apple-system;color:#fff;background:#ff3b30;padding:3px 7px;border-radius:5px;';
      tip.textContent = 'Click to zap · Esc to stop';
      document.documentElement.append(box, tip);
      let target = null;
      const describe = (el) => {
        const text = (el.getAttribute('aria-label') || el.innerText || el.alt || '').trim().replace(/\\s+/g, ' ').slice(0, 40);
        return el.tagName.toLowerCase() + (text ? ' · ' + text : '');
      };
      const selectorFor = (el) => {
        const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s;
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 7) {
          if (node.id && document.querySelectorAll('#' + esc(node.id)).length === 1 && !/\\d{3,}/.test(node.id)) {
            parts.unshift('#' + esc(node.id));
            break;
          }
          let part = node.tagName.toLowerCase();
          const stable = [...node.classList].filter(c => c.length < 30 && !/\\d{3,}|^(css|sc|jsx|_)-?[a-z0-9]{4,}$/i.test(c)).slice(0, 2);
          if (stable.length) part += '.' + stable.map(esc).join('.');
          const parent = node.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.tagName === node.tagName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
          }
          parts.unshift(part);
          node = node.parentElement;
        }
        return parts.join(' > ');
      };
      const move = (e) => {
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === box || el === tip) return;
        target = el;
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        Object.assign(tip.style, { left: Math.max(4, r.left) + 'px', top: Math.max(4, r.top - 24) + 'px' });
      };
      const finish = (value) => {
        removeEventListener('mousemove', move, true);
        removeEventListener('click', click, true);
        removeEventListener('keydown', key, true);
        box.remove(); tip.remove();
        resolve(value);
      };
      const click = (e) => {
        e.preventDefault(); e.stopPropagation();
        if (!target) return finish(null);
        target.style.setProperty('display', 'none', 'important');
        finish({ selector: selectorFor(target), label: describe(target) });
      };
      const key = (e) => { if (e.key === 'Escape') { e.preventDefault(); finish(null); } };
      addEventListener('mousemove', move, true);
      addEventListener('click', click, true);
      addEventListener('keydown', key, true);
    });
    """

    static func pick(on page: any EnginePage) async -> SiteBoost.Zap? {
        guard let raw = try? await page.evaluate(script, inWorld: PageBoost.world) as? [String: Any],
              let selector = raw["selector"] as? String, !selector.isEmpty else { return nil }
        return SiteBoost.Zap(selector: selector, label: raw["label"] as? String ?? selector)
    }
}
