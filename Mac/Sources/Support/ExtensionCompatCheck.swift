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
        // Hands-on mode: install, open a page, and leave Browsa Dev open for a person to try things.
        if ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_HANDS_ON"] != nil {
            _ = library.openExtensionTab(url: URL(string: "https://en.wikipedia.org/wiki/Web_browser"), windowID: nil, active: true)
            note("hands-on: left open")
            return
        }

        guard let engine = library.engine as? WebKitEngine else { note("not the WebKit engine"); exit(1) }
        for ext in engine.debugExtensionPopups().sorted(by: { $0.name < $1.name }) {
            if !ext.errors.isEmpty { note("[\(ext.name)] errors: \(ext.errors.joined(separator: " | ").prefix(600))") }
            let slug = ext.name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20)
            guard let popup = ext.popup else { note("[\(ext.name)] no popup"); continue }
            guard let page = library.openExtensionTab(url: popup, windowID: nil, active: true) else { note("[\(ext.name)] couldn't open popup"); continue }
            await pause(ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_POPUP_WAIT"].flatMap(Double.init) ?? 8)
            let summary = await evaluate(page, """
            (() => {
              const text = (document.body && document.body.innerText || '').replace(/\\s+/g, ' ').trim();
              const words = ['sign in', 'log in', 'login', 'create account', 'unlock', 'get started', 'continue with', 'sign up', 'email'];
              return JSON.stringify({ title: document.title, elements: document.querySelectorAll('*').length,
                text: text.slice(0, 160), signIn: words.filter(w => text.toLowerCase().includes(w)) });
            })()
            """)
            note("[\(ext.name)] popup \(popup.lastPathComponent): \(summary)")
            note("[\(ext.name)] missing here: \(await evaluate(page, """
            (() => { if (!globalThis.chrome) return 'no chrome global';
              return JSON.stringify(["alarms.clear", "alarms.clearAll", "alarms.create", "alarms.get", "alarms.onAlarm", "commands.getAll", "contextMenus.create", "cookies.get", "cookies.getAll", "cookies.onChanged", "contextMenus.remove", "contextMenus.removeAll", "extension.getBackgroundPage", "extension.getViews", "i18n.getMessage", "i18n.getUILanguage", "management.getSelf", "notifications.clear", "notifications.create", "notifications.onButtonClicked", "notifications.onClicked", "offscreen.Reason.CLIPBOARD", "offscreen.Reason.LOCAL", "offscreen.closeDocument", "offscreen.createDocument", "offscreen.hasDocument", "permissions.contains", "permissions.request", "privacy.services.autofillAddressEnabled", "privacy.services.autofillCreditCardEnabled", "privacy.services.passwordSavingEnabled", "runtime.MessageSender", "runtime.connect", "runtime.connectNative", "runtime.getContexts", "runtime.getManifest", "runtime.getPlatformInfo", "runtime.getURL", "runtime.id", "runtime.lastError", "runtime.onConnect", "runtime.onMessage", "runtime.reload", "runtime.sendMessage", "runtime.sendNativeMessage", "scripting.ExecutionWorld.ISOLATED", "scripting.ExecutionWorld.MAIN", "scripting.executeScript", "scripting.insertCSS", "scripting.registerContentScripts", "scripting.unregisterContentScripts", "sidePanel.open", "sidePanel.setOptions", "storage.local", "storage.local.get", "storage.managed", "storage.managed.get", "storage.onChanged", "storage.session", "storage.sync", "tabs.TAB", "tabs.Tab", "tabs.captureVisibleTab", "tabs.create", "tabs.executeScript", "tabs.get", "tabs.getCurrent", "tabs.onActivated", "tabs.onCreated", "tabs.onRemoved", "tabs.onUpdated", "tabs.query", "tabs.remove", "tabs.sendMessage", "tabs.update", "webNavigation.getAllFrames", "webNavigation.getFrame", "webNavigation.onCommitted", "webNavigation.onErrorOccurred", "webRequest.onAuthRequired", "windows.WINDOW", "windows.create", "windows.get", "windows.getAll", "windows.getCurrent", "windows.onRemoved", "windows.remove", "windows.update"].filter(p => p.split('.').reduce((o, k) => o == null ? undefined : o[k], chrome) === undefined)); })()
            """))")
            note("[\(ext.name)] popup messaging: \(await evaluate(page, """
            Promise.race([
              Promise.resolve().then(() => chrome.runtime.sendMessage({ type: 'PING', name: 'browsa-probe' })).then(r => 'reply ' + JSON.stringify(r), e => 'error ' + (e && e.message)),
              new Promise(r => setTimeout(() => r('no answer in 3 s'), 3000))
            ]).then(r => r + ' | browser.runtime: ' + typeof (globalThis.browser && browser.runtime) + ' | lastError path ok')
            """))")
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
            ("translate selection", "https://de.wikipedia.org/wiki/Webbrowser", """
            new Promise(r => {
              const p = document.querySelector('#mw-content-text p:not(.mw-empty-elt)'); const range = document.createRange();
              range.selectNodeContents(p); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
              const rect = p.getBoundingClientRect();
              for (const type of ['mousedown', 'mouseup']) p.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: rect.left + 20, clientY: rect.top + 10 }));
              setTimeout(() => r(JSON.stringify({ selected: String(sel).length, bubble: [...document.querySelectorAll('[id^="gtx"], [class*="gtx"]')].map(e => e.tagName.toLowerCase() + '#' + e.id).slice(0, 5) })), 4000);
            })
            """),
            ("json viewer", "https://api.github.com/", """
            JSON.stringify({ formatted: !!document.querySelector('#jsonFormatterParsed, #jsonFormatterRaw, .json-formatter-container, [class*="jsonFormatter"]'),
              bodyStart: (document.body && document.body.innerText || '').slice(0, 60), styles: document.querySelectorAll('style').length })
            """),
            ("keyboard hints", "https://example.com", """
            new Promise(r => {
              document.body.focus();
              for (const type of ['keydown', 'keypress', 'keyup']) document.dispatchEvent(new KeyboardEvent(type, { key: 'f', code: 'KeyF', bubbles: true }));
              setTimeout(() => r(JSON.stringify({ vimiumHosts: [...document.querySelectorAll('[class*="vimium"], [id*="vimium"]')].map(e => e.tagName.toLowerCase() + '.' + e.className).slice(0, 5),
                hints: document.querySelectorAll('.vimiumHintMarker').length + [...document.querySelectorAll('*')].filter(e => e.shadowRoot).reduce((n, e) => n + e.shadowRoot.querySelectorAll('.vimiumHintMarker').length, 0) })), 2000);
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
        // Real input: some extensions ignore scripted events (isTrusted false), so these go through AppKit.
        if let target = URL(string: "https://example.com"), let page = library.openExtensionTab(url: target, windowID: nil, active: true) {
            await pause(6)
            let before = await evaluate(page, "document.querySelectorAll('*').length")
            press(page.view, "f", keyCode: 3)
            await pause(1.5)
            note("[real key f] example.com: elements \(before) -> \(await evaluate(page, "document.querySelectorAll('*').length")), new: \(await evaluate(page, "JSON.stringify([...document.documentElement.children, ...document.body.children].slice(-3).map(e => e.tagName.toLowerCase() + '.' + e.className + (e.shadowRoot ? ' shadow:' + e.shadowRoot.querySelectorAll('*').length : '')))"))")
            await saveImage(await page.snapshot(), "real-key-f")
            press(page.view, "\u{1b}", keyCode: 53)
        }
        if let target = URL(string: "https://de.wikipedia.org/wiki/Webbrowser"), let page = library.openExtensionTab(url: target, windowID: nil, active: true) {
            await pause(8)
            let spot = await evaluate(page, "(() => { const p = document.querySelector('#mw-content-text p:not(.mw-empty-elt)'); p.scrollIntoView({ block: 'center' }); const r = document.createRange(); r.setStart(p.firstChild.nodeType === 3 ? p.firstChild : p, 0); const b = p.getBoundingClientRect(); return JSON.stringify([b.left + 2, b.top + 8, b.left + Math.min(b.width - 4, 300), b.top + 8]); })()")
            await pause(1)
            if let data = spot.data(using: .utf8), let xy = try? JSONSerialization.jsonObject(with: data) as? [Double], xy.count == 4 {
                await dragSelect(page.view, from: NSPoint(x: xy[0], y: xy[1]), to: NSPoint(x: xy[2], y: xy[3]))
                await pause(3)
                note("[real selection] de.wikipedia: \(await evaluate(page, "JSON.stringify({ selected: String(getSelection()).slice(0, 40), new: [...document.documentElement.children, ...document.body.children].slice(-3).map(e => e.tagName.toLowerCase() + '#' + e.id + '.' + e.className), gtx: document.querySelectorAll('[id^=\"gtx\"], [class*=\"gtx\"]').length })"))")
                await saveImage(await page.snapshot(), "real-selection")
            } else { note("[real selection] couldn't place the mouse: \(spot)") }
        }
        // Paper Snapshot: start its picker, click the heading, and see whether HTML reached the clipboard.
        if let paper = engine.debugExtensionPopups().first(where: { $0.name == "Paper Snapshot" }),
           let target = URL(string: "https://example.com"), let page = library.openExtensionTab(url: target, windowID: nil, active: true) {
            await pause(6)
            NSPasteboard.general.clearContents()
            engine.performAction(extensionID: paper.id, for: page, anchor: nil)
            await pause(3)
            let spot = await evaluate(page, "(() => { const b = document.querySelector('h1, p').getBoundingClientRect(); return JSON.stringify([b.left + b.width / 2, b.top + b.height / 2]); })()")
            if let data = spot.data(using: .utf8), let xy = try? JSONSerialization.jsonObject(with: data) as? [Double], xy.count == 2 {
                // The first click starts the picker ("Click the page to start"); the second takes the snapshot.
                await click(page.view, at: NSPoint(x: xy[0], y: xy[1]))
                await pause(2)
                await click(page.view, at: NSPoint(x: xy[0], y: xy[1]))
                await pause(5)
                let html = NSPasteboard.general.string(forType: .html)
                note("[Paper Snapshot] copy: clipboard html \(html.map { "\($0.count) chars, \($0.contains("x-paper") ? "Paper's" : "other")" } ?? "none"), page says: \(await evaluate(page, "(document.querySelector('#x-paper-toast') || {}).innerText || ''"))")
                await saveImage(await page.snapshot(), "paper-copy")
            } else { note("[Paper Snapshot] couldn't find the heading: \(spot)") }
        } else { note("[Paper Snapshot] copy test skipped") }
        note("done")
        exit(0)
    }

    private func click(_ view: NSView, at p: NSPoint) async {
        guard let window = view.window else { return }
        window.makeKeyAndOrderFront(nil)
        let point = view.convert(view.isFlipped ? p : NSPoint(x: p.x, y: view.bounds.height - p.y), to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(e) }
            await pause(0.3)
        }
    }

    private func press(_ view: NSView, _ chars: String, keyCode: UInt16) {
        guard let window = view.window else { note("no window for key"); return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) { window.sendEvent(e) }
        }
    }

    /// Mouse down, drag and up in page (CSS pixel, top-left) coordinates.
    private func dragSelect(_ view: NSView, from a: NSPoint, to b: NSPoint) async {
        guard let window = view.window else { note("no window for mouse"); return }
        window.makeKeyAndOrderFront(nil)
        func point(_ p: NSPoint) -> NSPoint { view.convert(view.isFlipped ? p : NSPoint(x: p.x, y: view.bounds.height - p.y), to: nil) }
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        note("mouse: flipped=\(view.isFlipped) bounds=\(view.bounds.size) a=\(point(a)) hit=\(window.contentView?.hitTest(point(a)).map { "\(type(of: $0))" } ?? "nil")")
        if let e = event(.leftMouseDown, a) { window.sendEvent(e) }
        for i in 1...10 {
            await pause(0.02)
            if let e = event(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * Double(i) / 10, y: a.y + (b.y - a.y) * Double(i) / 10)) { window.sendEvent(e) }
        }
        if let e = event(.leftMouseUp, b) { window.sendEvent(e) }
        // Then a double-click on a word, the other usual way to select.
        await pause(1)
        for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
            if let e = NSEvent.mouseEvent(with: type, location: point(NSPoint(x: a.x + 40, y: a.y)), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) { window.sendEvent(e) }
            await pause(0.05)
        }
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
