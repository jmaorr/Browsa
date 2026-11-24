import Foundation

/// Colour for a Boost that isn't a wash over the page.
///
/// - Accent: finds the site's own brand colour (the hue its links, buttons and highlights share) and
///   swaps it for another, keeping its lightness and strength, so greys, text and photos stay as
///   they are. Read from the site's style sheets where it can, and from what's on screen for style
///   sheets it can't read (other domains), with new content picked up as it arrives.
/// - Look: Dark (the page inverted, with photos and video turned back) or Muted (calmer colours).
enum BoostColour {
    enum Look: String, Codable, CaseIterable, Identifiable {
        case original, dark, muted
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: "Original"
            case .dark: "Dark"
            case .muted: "Muted"
            }
        }

        var css: String? {
            switch self {
            case .original: nil
            case .dark:
                """
                html { filter: invert(1) hue-rotate(180deg) !important; background: #fff !important; }
                img, video, picture, canvas, iframe, embed, object, svg image, [style*="background-image"] {
                  filter: invert(1) hue-rotate(180deg) !important;
                }
                """
            case .muted:
                """
                html { filter: saturate(0.5) !important; }
                img, video, picture, canvas, iframe { filter: saturate(2) !important; }
                """
            }
        }
    }

    /// Run in the Boost world: recolours the page's accent to `hue`, or puts it back with nil.
    static func accentSource(_ hue: Double?) -> String {
        let arg = hue.map { String(Int($0.rounded())) } ?? "null"
        return accentFunction + "\n__browsaAccent(\(arg));"
    }

    /// The same, for a page that's loading: once now, and again when it finishes.
    static func accentOnLoad(_ hue: Double) -> String {
        let h = Int(hue.rounded())
        return accentFunction + "\n__browsaAccent(\(h)); addEventListener('load', () => __browsaAccent(\(h)), { once: true });"
    }

    static let accentFunction = """
    globalThis.__browsaAccent = globalThis.__browsaAccent || (() => {
      const PROPS = ['color', 'background-color', 'border-top-color', 'border-right-color', 'border-bottom-color',
        'border-left-color', 'outline-color', 'fill', 'stroke', 'text-decoration-color', 'caret-color', 'accent-color'];
      const SKIP = new Set(['IMG', 'VIDEO', 'PICTURE', 'CANVAS', 'IFRAME', 'SCRIPT', 'STYLE', 'NOSCRIPT']);
      const st = { sheet: null, inline: [], done: new WeakSet(), observer: null, target: null, dominant: null, sheetCount: -1, timer: 0 };

      const parse = (v) => {
        if (!v) return null;
        v = v.trim();
        let m = /^rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+%?))?\\s*\\)$/i.exec(v);
        if (m) {
          const a = m[4] === undefined ? 1 : (m[4].endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]));
          return [+m[1], +m[2], +m[3], a];
        }
        m = /^#([0-9a-f]{3,8})$/i.exec(v);
        if (m) {
          let x = m[1];
          if (x.length <= 4) x = [...x].map(c => c + c).join('');
          const n = parseInt(x.slice(0, 6), 16);
          return [(n >> 16) & 255, (n >> 8) & 255, n & 255, x.length === 8 ? parseInt(x.slice(6), 16) / 255 : 1];
        }
        return null;
      };
      const hsl = ([r, g, b]) => {
        r /= 255; g /= 255; b /= 255;
        const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
        if (max === min) return [0, 0, l];
        const d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        let h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
        return [h * 60, s, l];
      };
      const vivid = (c) => { if (!c || c[3] < 0.2) return null; const x = hsl(c); return x[1] > 0.28 && x[2] > 0.12 && x[2] < 0.9 ? x : null; };
      const near = (h, d) => Math.abs(((h - d + 540) % 360) - 180) <= 30;
      const shifted = (c, x) => {
        const h = ((st.target + (x[0] - st.dominant)) % 360 + 360) % 360;
        return `hsl(${h.toFixed(0)} ${(x[1] * 100).toFixed(1)}% ${(x[2] * 100).toFixed(1)}% / ${c[3]})`;
      };

      // Every style rule we can read, with the @media/@supports it sits in.
      const rules = () => {
        const out = [];
        const walk = (list, wrap) => {
          for (const r of list) {
            if (r.style && r.selectorText) out.push([r, wrap]);
            else if (r.cssRules && r.conditionText !== undefined) {
              const at = r instanceof CSSMediaRule ? '@media ' : (typeof CSSContainerRule !== 'undefined' && r instanceof CSSContainerRule) ? '@container ' : '@supports ';
              walk(r.cssRules, [...wrap, at + r.conditionText]);
            } else if (r.cssRules && typeof CSSLayerBlockRule !== 'undefined' && r instanceof CSSLayerBlockRule) walk(r.cssRules, wrap);
          }
        };
        for (const s of document.styleSheets) { try { if (s !== st.sheet) walk(s.cssRules, []); } catch (e) {} }
        return out;
      };

      // The site's accent: the hue its vivid colours share most, with links and buttons counting extra.
      const findDominant = (list) => {
        const buckets = new Array(24).fill(0);
        const add = (x, w) => { if (x) buckets[Math.floor(x[0] / 15) % 24] += w; };
        for (const [r] of list) {
          for (const p of PROPS) add(vivid(parse(r.style.getPropertyValue(p))), 1);
          for (let i = 0; i < r.style.length; i++) { const n = r.style[i]; if (n.startsWith('--')) add(vivid(parse(r.style.getPropertyValue(n))), 2); }
        }
        let i = 0;
        for (const el of document.querySelectorAll('a, button, [role=button], [role=tab], nav *, header *, input[type=submit]')) {
          if (++i > 400) break;
          const cs = getComputedStyle(el);
          add(vivid(parse(cs.color)), 3); add(vivid(parse(cs.backgroundColor)), 4);
        }
        let best = -1, bestW = 0;
        for (let b = 0; b < 24; b++) {
          const w = buckets[b] * 2 + buckets[(b + 23) % 24] + buckets[(b + 1) % 24];
          if (w > bestW) { bestW = w; best = b; }
        }
        if (bestW < 6) return null;
        // Centre on the strongest bucket and its neighbours.
        const l = buckets[(best + 23) % 24], c = buckets[best], r = buckets[(best + 1) % 24];
        return (best * 15 + 7.5 + ((r - l) / Math.max(1, l + c + r)) * 15 + 360) % 360;
      };

      const rewriteSheets = (list) => {
        const out = [];
        for (const [r, wrap] of list) {
          const decl = [];
          for (const p of PROPS) {
            const c = parse(r.style.getPropertyValue(p)), x = vivid(c);
            if (x && near(x[0], st.dominant)) decl.push(`${p}: ${shifted(c, x)}${r.style.getPropertyPriority(p) ? ' !important' : ''}`);
          }
          for (let i = 0; i < r.style.length; i++) {
            const n = r.style[i];
            if (!n.startsWith('--')) continue;
            const c = parse(r.style.getPropertyValue(n)), x = vivid(c);
            if (x && near(x[0], st.dominant)) decl.push(`${n}: ${shifted(c, x)}`);
          }
          if (!decl.length) continue;
          let text = `${r.selectorText} { ${decl.join('; ')} }`;
          for (const w of [...wrap].reverse()) text = `${w} { ${text} }`;
          out.push(text);
        }
        if (!st.sheet) {
          st.sheet = new CSSStyleSheet();
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, st.sheet];
        }
        try { st.sheet.replaceSync(out.join('\\n')); } catch (e) {
          st.sheet.replaceSync(out.filter(t => { try { new CSSStyleSheet().replaceSync(t); return true; } catch (_) { return false; } }).join('\\n'));
        }
      };

      // What style sheets from other domains coloured: fixed on the elements themselves.
      const fixElements = (root) => {
        // A new accent close to the old one: what the sheets changed would look unchanged here, and
        // shift twice. The sheets alone do it.
        if (near(st.target, st.dominant)) return;
        const all = root.querySelectorAll ? [root, ...root.querySelectorAll('*')] : [];
        let n = 0;
        for (const el of all) {
          if (++n > 5000) break;
          if (!(el instanceof Element) || st.done.has(el) || SKIP.has(el.tagName.toUpperCase())) continue;
          st.done.add(el);
          const cs = getComputedStyle(el);
          for (const p of PROPS) {
            const c = parse(cs.getPropertyValue(p)), x = vivid(c);
            if (!x || !near(x[0], st.dominant)) continue;
            st.inline.push([el, p, el.style.getPropertyValue(p), el.style.getPropertyPriority(p)]);
            el.style.setProperty(p, shifted(c, x), 'important');
          }
        }
      };

      const restore = () => {
        for (const [el, p, old, pri] of st.inline) { if (old) el.style.setProperty(p, old, pri); else el.style.removeProperty(p); }
        st.inline = [];
        st.done = new WeakSet();
      };

      const run = () => {
        restore();
        const list = rules();
        st.dominant = findDominant(list);
        if (st.dominant === null) { if (st.sheet) st.sheet.replaceSync(''); return; }
        rewriteSheets(list);
        if (document.body) fixElements(document.body);
        st.sheetCount = document.styleSheets.length;
      };

      return (target) => {
        st.target = target;
        if (target === null || target === undefined) {
          st.observer?.disconnect(); st.observer = null;
          restore();
          if (st.sheet) st.sheet.replaceSync('');
          return;
        }
        run();
        if (st.observer) return;
        // New content in the accent colour (menus, infinite feeds): fixed as it arrives, a few times a second at most.
        const pending = new Set();
        st.observer = new MutationObserver((records) => {
          for (const r of records) for (const node of r.addedNodes) if (node.nodeType === 1) pending.add(node);
          if (st.timer) return;
          st.timer = setTimeout(() => {
            st.timer = 0;
            if (st.target === null || st.dominant === null) { pending.clear(); return; }
            if (document.styleSheets.length !== st.sheetCount) { pending.clear(); run(); return; }
            for (const node of pending) if (node.isConnected) fixElements(node);
            pending.clear();
          }, 400);
        });
        st.observer.observe(document.documentElement, { childList: true, subtree: true });
      };
    })();
    """
}
