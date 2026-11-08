#if DEBUG
import AppKit
import BrowserEngine
import WebKitEngine

/// Debug only: with BROWSA_EXT_COMPAT_CHECK=<folder>, installs Chrome Web Store extensions through
/// Browsa's own store flow (ids in BROWSA_EXT_COMPAT_IDS, space-separated), then checks each one:
/// its popup opens and what it shows (text and a PNG), and what its content scripts did on a few test
/// pages. Background lifecycle is in the [ext-log] lines (run with BROWSA_EXT_DIAGNOSTICS=1).
/// Writes compat.txt and PNGs, then quits. Never signs in to anything.
@MainActor
struct ExtensionCompatCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        let library = delegate.library
        let ids = (ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_IDS"] ?? "").split(separator: " ").map(String.init)

        // Install through the same path as Settings > Extensions.
        for id in ids {
            do {
                let preview = try await library.previewExtension(link: id)
                library.extensionCatalog.upsert(preview.item)
                note("installed \(preview.item.name) \(preview.item.version) (\(id))")
            } catch {
                note("install failed \(id): \(error)")
            }
        }
        library.reloadExtensions()
        await pause(20)
        note("running: \(library.extensions.map(\.name))")

        guard let engine = library.engine as? WebKitEngine else { note("not the WebKit engine"); exit(1) }
        for ext in engine.debugExtensionPopups().sorted(by: { $0.name < $1.name }) {
            if !ext.errors.isEmpty { note("[\(ext.name)] errors: \(ext.errors.joined(separator: " | ").prefix(600))") }
            let slug = ext.name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20)
            guard let popup = ext.popup else { note("[\(ext.name)] no popup"); continue }
            guard let page = library.openExtensionTab(url: popup, windowID: nil, active: true) else { note("[\(ext.name)] couldn't open popup"); continue }
            await pause(8)
            let summary = await evaluate(page, """
            (() => {
              const text = (document.body && document.body.innerText || '').replace(/\\s+/g, ' ').trim();
              const words = ['sign in', 'log in', 'login', 'create account', 'unlock', 'get started', 'continue with', 'sign up', 'email'];
              return JSON.stringify({ title: document.title, elements: document.querySelectorAll('*').length,
                text: text.slice(0, 160), signIn: words.filter(w => text.toLowerCase().includes(w)) });
            })()
            """)
            note("[\(ext.name)] popup \(popup.lastPathComponent): \(summary)")
            await saveImage(await page.snapshot(), "popup-\(slug)")
            library.closeExtensionTab(page)
        }

        // Content scripts on real pages.
        let probes: [(String, String, String)] = [
            ("login page", "https://github.com/login", """
            (() => {
              const all = [...document.querySelectorAll('*')];
              const marks = all.filter(e => /bitwarden|lastpass|dashlane|proton|onepassword|1password|grammarly/i.test(e.tagName + ' ' + [...e.attributes].map(a => a.name + '=' + a.value).join(' ')))
                .slice(0, 12).map(e => e.tagName.toLowerCase() + [...e.attributes].map(a => ' ' + a.name).join('').slice(0, 60));
              return JSON.stringify({ marks, shadowHosts: all.filter(e => e.shadowRoot).length });
            })()
            """),
            ("dark mode", "https://example.com", """
            JSON.stringify({ background: getComputedStyle(document.documentElement).backgroundColor + ' / ' + getComputedStyle(document.body).backgroundColor,
              darkReader: !!document.querySelector('style.darkreader, meta[name="darkreader"]') })
            """),
            ("ad blocking", "https://example.org", """
            Promise.all(['https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js', 'https://www.google-analytics.com/analytics.js', 'https://example.com/']
              .map(u => fetch(u, { mode: 'no-cors', cache: 'no-store' }).then(() => u.split('/')[2] + ' loaded', () => u.split('/')[2] + ' blocked')))
              .then(r => JSON.stringify(r))
            """),
            ("writing", "https://en.wikipedia.org/wiki/Special:Search", """
            new Promise(r => {
              const t = document.createElement('textarea'); t.style.cssText = 'position:fixed;top:80px;left:20px;width:400px;height:120px;z-index:99999';
              document.body.append(t); t.focus(); t.value = 'This are a sentence with a error in it.'; t.dispatchEvent(new Event('input', { bubbles: true }));
              setTimeout(() => r(JSON.stringify({ grammarly: [...document.querySelectorAll('grammarly-extension, grammarly-desktop-integration, [data-grammarly-shadow-root], [data-gr-ext-installed]')].map(e => e.tagName.toLowerCase()).slice(0, 5),
                attrs: [...document.body.attributes, ...document.documentElement.attributes].map(a => a.name).filter(n => /gr|translate|grammar/i.test(n)) })), 8000);
            })
            """),
        ]
        for (name, url, js) in probes {
            guard let target = URL(string: url), let page = library.openExtensionTab(url: target, windowID: nil, active: true) else { continue }
            await pause(8)
            note("[\(name)] \(url): \(await evaluate(page, js))")
            await saveImage(await page.snapshot(), "page-\(name.replacingOccurrences(of: " ", with: "-"))")
        }
        // Toolbar-button extensions (no popup): click the button on a page and see what appears.
        if let target = URL(string: "https://en.wikipedia.org/wiki/Web_browser"), let page = library.openExtensionTab(url: target, windowID: nil, active: true) {
            await pause(6)
            let before = await evaluate(page, "document.querySelectorAll('*').length")
            for ext in engine.debugExtensionPopups() where ext.popup == nil && ext.id.hasPrefix("chrome:") {
                engine.performAction(extensionID: ext.id, for: page, anchor: nil)
                await pause(4)
                note("[\(ext.name)] clicked its button: elements \(before) -> \(await evaluate(page, "document.querySelectorAll('*').length")), new hosts: \(await evaluate(page, "JSON.stringify([...document.querySelectorAll('body > *')].slice(-3).map(e => e.tagName.toLowerCase() + '#' + e.id))"))")
                await saveImage(await page.snapshot(), "action-\(ext.name.lowercased().filter { $0.isLetter }.prefix(16))")
            }
        }
        note("done")
        exit(0)
    }

    private func evaluate(_ page: any EnginePage, _ js: String) async -> String {
        do { return "\(try await page.evaluate("return await (\(js))", inWorld: "page") ?? "nil")" }
        catch { return "error: \(error.localizedDescription)" }
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("[compat] \(line)\n".utf8))
        let url = directory.appending(path: "compat.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    private func saveImage(_ image: CGImage?, _ name: String) async {
        guard let image else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
