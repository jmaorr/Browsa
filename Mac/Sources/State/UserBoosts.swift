import Foundation
import Observation
import BrowserCore
import BrowserEngine

/// A Boost you make yourself for one site, like Arc's: a font, a tint, things zapped away, and CSS and a
/// script if you want them. Stored on this Mac and never sent anywhere.
///
/// Ready-made Boosts (`Boost`, like LinkedIn Tidy Feed) sit beside these and are turned on by id. The engine
/// runs these through `BoostsConfigurable.userBoosts`: styles go in before the page draws, scripts after it
/// loads, both in their own world, so a Boost never sees the page's JavaScript.
struct SiteBoost: Codable, Identifiable, Equatable {
    enum Font: String, Codable, CaseIterable, Identifiable {
        case site, system, serif, rounded, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .site: "Original"
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
    /// The site's accent colour swapped for this hue (0–360). Nil keeps the site's own. Stored as
    /// "tint", its name when it was a wash over the page.
    var tint: Double?
    /// Dark or Muted, or the site as it comes.
    var look: BoostColour.Look = .original
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

    private enum CodingKeys: String, CodingKey {
        case id, host, isOn, font, tint, look, zaps, css, script, created
    }

    /// Boosts saved before a setting existed still load, with that setting at its default.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        font = (try? c.decodeIfPresent(Font.self, forKey: .font)) ?? .site
        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        look = (try? c.decodeIfPresent(BoostColour.Look.self, forKey: .look)) ?? .original
        zaps = try c.decodeIfPresent([Zap].self, forKey: .zaps) ?? []
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    /// Everything the choices add up to, as one style sheet.
    var effectiveCSS: String {
        var parts: [String] = []
        if let family = font.family {
            parts.append(":where(body, p, li, h1, h2, h3, h4, h5, h6, a, td, th, dd, dt, blockquote, input, textarea, button, label, figcaption) { font-family: \(family) !important; }")
        }
        if let look = look.css { parts.append(look) }
        if !zaps.isEmpty {
            parts.append(zaps.map(\.selector).joined(separator: ",\n") + " { display: none !important; }")
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(css) }
        return parts.joined(separator: "\n")
    }

    /// The accent swap (it reads the page, so it's a script), then the script you wrote.
    var effectiveScript: String {
        var parts: [String] = []
        if let tint { parts.append(BoostColour.accentOnLoad(tint)) }
        if !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(script) }
        return parts.joined(separator: "\n")
    }

    var isEmpty: Bool {
        font == .site && tint == nil && look == .original && zaps.isEmpty
            && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What it changes, in a few words, for lists: "Serif · Tint · 2 zapped".
    var summary: String {
        var parts: [String] = []
        if font != .site { parts.append(font.title) }
        if look != .original { parts.append(look.title) }
        if tint != nil { parts.append("Accent") }
        if !zaps.isEmpty { parts.append("\(zaps.count) zapped") }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("CSS") }
        if !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Script") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }

    /// The part of the address a Boost is keyed by: the host without "www.".
    static func key(for url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func matches(_ host: String) -> Bool { host == self.host || host.hasSuffix("." + self.host) }
}

/// The Boosts you've made, saved in `Browser/boosts.json`.
@MainActor @Observable
final class BoostStore {
    static let shared = BoostStore()

    private(set) var boosts: [SiteBoost] = []
    @ObservationIgnored private weak var engine: (any BoostsConfigurable)?
    @ObservationIgnored private let fileURL = AppFolders.support.appending(path: "Browser/boosts.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The accent last previewed on each open page, so turning it off puts the page back.
    @ObservationIgnored private var lastPreviewAccent: [ObjectIdentifier: Double] = [:]
    @ObservationIgnored private var accentTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The Library's Boosts switch is off: nothing applies, nothing is lost.
    var paused = false {
        didSet { if paused != oldValue { push() } }
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([SiteBoost].self, from: data) {
            boosts = saved
        }
    }

    /// Called once the engine exists. Pages loaded from now on get every Boost that's on.
    func attach(engine: (any BoostsConfigurable)?) {
        self.engine = engine
        push()
    }

    func boost(for url: URL?) -> SiteBoost? {
        guard let key = SiteBoost.key(for: url) else { return nil }
        return boosts.first { $0.host == key } ?? boosts.first { $0.matches(key) }
    }

    /// The Boost for this site, or a new empty one (not saved until it changes something).
    func boostOrNew(for url: URL?) -> SiteBoost? {
        if let b = boost(for: url) { return b }
        guard let key = SiteBoost.key(for: url) else { return nil }
        return SiteBoost(host: key)
    }

    /// Saves a change. A Boost that changes nothing isn't kept, so trying one out and undoing it leaves no trace.
    func save(_ boost: SiteBoost) {
        if let i = boosts.firstIndex(where: { $0.id == boost.id }) {
            if boost.isEmpty { boosts.remove(at: i) } else { boosts[i] = boost }
        } else if !boost.isEmpty {
            boosts.append(boost)
        } else {
            return
        }
        changed()
    }

    func setOn(_ id: UUID, _ on: Bool) {
        guard let i = boosts.firstIndex(where: { $0.id == id }), boosts[i].isOn != on else { return }
        boosts[i].isOn = on
        changed()
    }

    /// A new, empty Boost for a site you type in the Library. Kept once it changes something.
    func newBoost(forAddress address: String) -> SiteBoost? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        return boostOrNew(for: URL(string: text))
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
        engine?.userBoosts = paused ? [] : boosts.filter(\.isOn).map { PageBoost(host: $0.host, css: $0.effectiveCSS, script: $0.effectiveScript) }
    }

    /// Shows a Boost's style on a page now, without reloading. Its script runs on the next load.
    func preview(_ boost: SiteBoost?, on page: any EnginePage) async {
        let on = boost?.isOn == true
        let css = on ? boost?.effectiveCSS ?? "" : ""
        _ = try? await page.evaluate(PageBoost.previewSource(css: css), inWorld: PageBoost.world)
        // The accent swap reads the page; only worth running if it's on, or was.
        let hue = on ? boost?.tint : nil
        let key = ObjectIdentifier(page)
        guard hue != nil || lastPreviewAccent[key] != nil, hue != lastPreviewAccent[key] else { return }
        lastPreviewAccent[key] = hue
        // Dragging along the strip changes it every frame: recolour once it settles a moment.
        accentTasks[key]?.cancel()
        accentTasks[key] = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            _ = try? await page.evaluate(BoostColour.accentSource(hue) + "\nreturn true;", inWorld: PageBoost.world)
        }
    }
}

/// Zap: point at something on the page and click to hide it. Esc stops.
enum ZapPicker {
    /// Resolves with `{ selector, label }` once something is clicked, or null on Esc.
    static let script = """
    return await new Promise((resolve) => {
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b30;background:rgba(255,59,48,.12);border-radius:6px;transition:all .06s ease-out;';
      const tip = document.createElement('div');
      tip.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;font:600 11px -apple-system;color:#fff;background:#ff3b30;padding:3px 8px;border-radius:999px;';
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

    @MainActor static func pick(on page: any EnginePage) async -> SiteBoost.Zap? {
        guard let raw = try? await page.evaluate(script, inWorld: PageBoost.world) as? [String: Any],
              let selector = raw["selector"] as? String, !selector.isEmpty else { return nil }
        return SiteBoost.Zap(selector: selector, label: raw["label"] as? String ?? selector)
    }

    /// Zaps something on the current page into its site's Boost, from the site icon menu or ⌘K.
    @MainActor static func zapOnCurrentPage(in browser: Browser) {
        guard browser.currentTab?.isPrivate != true else {
            browser.showToast("Boosts aren't saved from private tabs"); return
        }
        guard let url = browser.currentTab?.url, let page = browser.currentController?.page,
              BoostStore.shared.boostOrNew(for: url) != nil else { return }
        Task {
            guard let zap = await pick(on: page), var boost = BoostStore.shared.boostOrNew(for: url) else { return }
            boost.zaps.append(zap)
            boost.isOn = true
            BoostStore.shared.save(boost)
            await BoostStore.shared.preview(boost, on: page)
            browser.showToast("Zapped. It stays hidden on \(boost.host)")
        }
    }
}
