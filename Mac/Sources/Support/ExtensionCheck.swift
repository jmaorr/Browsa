#if DEBUG
import AppKit
import WebKit
import BrowserEngine
import WebKitEngine

/// Debug only: with BROWSA_EXT_CHECK=<folder> set, opens github.com/login, clicks 1Password's
/// toolbar button, then focuses the username field, saving what the popup and the page show
/// (report.txt and PNGs), then quits. Spike for running installed Safari extensions.
@MainActor
struct ExtensionCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while (delegate.browser == nil || delegate.library.extensions.isEmpty), waited < 20 { await pause(0.5); waited += 0.5 }
        let library = delegate.library
        note("extensions after \(waited)s: \(library.extensions.map { "\($0.id) \($0.version) action=\($0.hasAction)" })")
        guard let browser = delegate.browser else { note("no window"); quit(); return }

        browser.newTab(url: URL(string: "https://github.com/login")!)
        await pause(8)
        let page = browser.currentController?.page
        note("tab: \(page?.state.url?.absoluteString ?? "-")")
        note("windows for extensions: \(library.extensionWindows.map { "\($0.id) pages=\($0.pages.count) active=\($0.activePage != nil)" })")

        let wanted = ProcessInfo.processInfo.environment["BROWSA_EXT_CHECK_NAME"] ?? "1Password"
        if let op = library.extensions.first(where: { $0.id.hasPrefix("unpacked.") && $0.name.contains(wanted) })
            ?? library.extensions.first(where: { $0.name.contains(wanted) }), let webkit = library.engine as? WebKitEngine {
            let probe = """
            const out = {};
            out.hasBrowser = typeof browser !== 'undefined';
            out.hasChrome = typeof chrome !== 'undefined';
            out.title = document.title;
            out.scripts = [...document.scripts].map(s => s.src.split('/').slice(-2).join('/'));
            const action = browser.action || browser.browserAction;
            try { out.popup = await action.getPopup({}); } catch (e) { out.popupError = String(e); }
            out.manifest = browser.runtime.getManifest().manifest_version;
            out.missing = ['idle','management','privacy','downloads','alarms','contextMenus','notifications','scripting','storage','tabs','webNavigation','webRequest','declarativeNetRequest','offscreen','runtime','action','permissions','i18n','windows','cookies','commands','sidePanel','identity']
              .filter(n => typeof chrome[n] === 'undefined');
            try {
              const r = await Promise.race([browser.runtime.sendNativeMessage('com.1password.1password', {type: 'ping'}),
                                            new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 5s')), 5000))]);
              out.native = JSON.stringify(r).slice(0, 300);
            } catch (e) { out.nativeError = String(e); }
            return JSON.stringify(out);
            """
            note("background before click: \(await webkit.debugExtensionBackground(op.id, probe))")
            let anchor = browser.nsWindow?.contentView
            library.engine.performAction(extensionID: op.id, for: page, anchor: anchor)
            for i in 0..<4 {
                await pause(4)
                await describePopup("popup-\(i)")
            }
            NSApp.windows.filter { "\(type(of: $0))".contains("Popover") }.forEach { $0.close() }
        } else {
            note("1Password not loaded")
        }

        if let op = library.extensions.first(where: { $0.id.hasPrefix("unpacked.") }), let webkit = library.engine as? WebKitEngine {
            let log = "const v = await chrome.storage.local.get(['__browsaWorker', '__browsaErrors', '__browsaBG']); return JSON.stringify(v).slice(0, 30000);"
            note("tabs after click: \(library.extensionWindows.map { $0.pages.map { $0.state.url?.absoluteString ?? "nil" } })")
            note("worker log after click: \(await webkit.debugExtensionBackground(op.id, log))")
        }

        // 1Password's own sign-in page, in a tab.
        if let op = library.extensions.first(where: { $0.id.hasPrefix("unpacked.") }), let webkit = library.engine as? WebKitEngine {
            let info = await webkit.debugExtensionBackground(op.id, "return location.origin")
            if let r = info.range(of: "webkit-extension://[0-9a-f-]+", options: .regularExpression) {
                let base = String(info[r])
                _ = base
                _ = await webkit.debugExtensionBackground(op.id, "await chrome.storage.local.remove(['__browsaErrors']); return 'cleared'")
                note("tabs.create: \(await webkit.debugExtensionBackground(op.id, "const t = await chrome.tabs.create({url: chrome.runtime.getURL('/app/app.html#/page/welcome')}); return JSON.stringify(t)"))")
                await pause(8)
                if let welcome = browser.currentController?.page {
                    let text = try? await welcome.evaluate("return JSON.stringify({ready: document.readyState, href: location.href, html: document.documentElement.outerHTML.length, body: document.body ? document.body.innerHTML.slice(0, 500) : null, scripts: [...document.scripts].map(s => s.src)})", inWorld: "browsa.check")
                    note("welcome page \(welcome.state.url?.absoluteString ?? "-"): \(String(describing: text))")
                    if let image = await welcome.snapshot() { save(image, "welcome") }
                }
                note("all web views: \(NSApp.windows.flatMap({ webViews(in: $0.contentView) }).map { "\($0.url?.absoluteString ?? "nil") loading=\($0.isLoading)" })")
                for web in NSApp.windows.flatMap({ webViews(in: $0.contentView) }) where web.url?.scheme == "webkit-extension" {
                    let r = try? await web.callAsyncJavaScript("return JSON.stringify({href: location.href, ready: document.readyState, body: document.body ? document.body.innerHTML.slice(0, 300) : null, chrome: typeof chrome, errs: (window.__browsaErrors || []).slice(0, 8)})", arguments: [:], in: nil, contentWorld: .page)
                    note("extension web view \(web.url!.absoluteString) loading=\(web.isLoading): \(String(describing: r))")
                    let direct = try? await web.callAsyncJavaScript("""
                    const out = {};
                    try { out.promise = String(JSON.stringify(await Promise.race([chrome.runtime.sendMessage({name: "browsa-ping"}), new Promise(r => setTimeout(() => r("timeout"), 3000))]))).slice(0, 6000); } catch (e) { out.promiseError = String(e); }
                    out.lastError = chrome.runtime.lastError && chrome.runtime.lastError.message;
                    out.id = chrome.runtime.id;
                    return JSON.stringify(out);
                    """, arguments: [:], in: nil, contentWorld: .page)
                    note("direct sendMessage: \(String(describing: direct))")
                }
                let log = "const v = await chrome.storage.local.get(['__browsaWorker', '__browsaErrors', '__browsaHeartbeat']); return JSON.stringify(v).slice(0, 40000);"
                note("logs after welcome: \(await webkit.debugExtensionBackground(op.id, log))")
                browser.close(browser.currentTab!)
                await pause(1)
            }
        }

        // The inline menu shows when a login field gets focus.
        let focus = """
        const f = document.querySelector('#login_field');
        if (!f) return 'no #login_field';
        f.focus(); f.click();
        return 'focused';
        """
        note("focus: \(String(describing: try? await page?.evaluate(focus, inWorld: "browsa.check")))")
        for i in 0..<3 {
            await pause(3)
            let probe = """
            const all = [...document.querySelectorAll('*')].filter(e => e.tagName.toLowerCase().includes('1password') || (e.id || '').includes('1password') || [...e.attributes].some(a => a.name.startsWith('data-com-onepassword') || a.name.startsWith('data-1p')));
            return JSON.stringify(all.slice(0, 12).map(e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + ' ' + [...e.attributes].map(a => a.name).join(',')));
            """
            note("1Password elements in page (\(i)): \(String(describing: try? await page?.evaluate(probe, inWorld: "browsa.check")))")
            if let image = await page?.snapshot() { save(image, "page-\(i)") }
        }
        let filled = "return JSON.stringify({user: document.querySelector('#login_field')?.value?.length ?? -1, pass: document.querySelector('#password')?.value?.length ?? -1})"
        note("field lengths: \(String(describing: try? await page?.evaluate(filled, inWorld: "browsa.check")))")
        quit()
    }

    /// The popover's web view: its text (vault, or a request to unlock) and a picture.
    private func describePopup(_ name: String) async {
        let webViews = NSApp.windows.filter { $0.isVisible }.flatMap { webViews(in: $0.contentView) }
            .filter { $0.window !== delegate.browser?.nsWindow }
        note("\(name): visible windows \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" }), popup web views \(webViews.count)")
        guard let web = webViews.first else { return }
        let text = (try? await web.callAsyncJavaScript("return (document.body ? document.body.innerText.slice(0, 500) + ' || html ' + document.body.innerHTML.length + ': ' + document.body.innerHTML.slice(0, 400) : 'no body') + ' || errors: ' + JSON.stringify((window.__browsaErrors || []).slice(0, 6)).slice(0, 600) + ' || apis: ' + JSON.stringify({session: typeof chrome.storage.session, getContexts: typeof chrome.runtime.getContexts, sessionSet: chrome.storage.session ? await chrome.storage.session.set({a:1}).then(()=>'ok',e=>String(e)) : 'none', ping: await Promise.race([chrome.runtime.sendMessage({browsaPing: 1}).then(r=>'reply '+JSON.stringify(r),e=>'err '+e), new Promise(r=>setTimeout(()=>r('timeout'),2000))])}) + ' || stored: ' + JSON.stringify(await new Promise(r => chrome.storage.local.get(['__browsaWorker', '__browsaErrors', '__browsaBG'], v => r(v)))).slice(0, 30000)", arguments: [:], in: nil, contentWorld: .page)) as? String
        note("\(name): url=\(web.url?.absoluteString ?? "-") size=\(web.frame.size) text=\(text?.replacingOccurrences(of: "\n", with: " | ") ?? "nil")")
        let config = WKSnapshotConfiguration()
        if let image = try? await web.takeSnapshot(configuration: config),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            save(cg, name)
        }
    }

    private func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private func note(_ line: String) {
        print("[ext-check] \(line)")
        let url = directory.appending(path: "report.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func save(_ image: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    /// Terminate can stall (native hosts, a popover), so exit regardless shortly after.
    private func quit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        NSApp.terminate(nil)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
