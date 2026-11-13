#if DEBUG
import AppKit

/// Debug only: with BROWSA_CHROME_CHECK=<folder> set, opens a Chrome-style window and records what
/// chrome://extensions shows and whether an extension (BROWSA_LOAD_EXTENSION) acts on
/// github.com/login, then quits. Spike for Chrome extension support on CEF.
@MainActor
struct ChromeStyleCheck {
    let directory: URL

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await pause(3)
        let window = BCEFChromeWindow(url: "chrome://extensions")
        await pause(8)
        let list = """
        (() => {
          const m = document.querySelector('extensions-manager');
          const l = m && m.shadowRoot.querySelector('extensions-item-list');
          const items = l ? [...l.shadowRoot.querySelectorAll('extensions-item')] : [];
          return JSON.stringify({title: document.title, url: location.href,
            items: items.map(e => ({name: e.data && e.data.name, id: e.data && e.data.id, state: e.data && e.data.state,
                                    errors: e.data && (e.data.runtimeErrors || []).length}))});
        })()
        """
        note("chrome://extensions: \(await evaluate(window, list))")
        await shot(window, "chrome-1-extensions")

        window.loadURL("https://chromewebstore.google.com/detail/1password-password-manager/aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        await pause(8)
        note("web store: \(await evaluate(window, "JSON.stringify({title: document.title, buttons: [...document.querySelectorAll('button')].map(b => b.innerText.trim()).filter(t => t).slice(0, 12)})"))")
        await shot(window, "chrome-2-webstore")

        window.loadURL("https://github.com/login")
        await pause(8)
        let probe = """
        (() => { const f = document.querySelector('#login_field'); if (f) { f.focus(); f.click(); }
          return new Promise(r => setTimeout(() => r(JSON.stringify({
            focused: !!f,
            onePassword: [...document.querySelectorAll('*')].filter(e => e.tagName.toLowerCase().includes('1password')
              || [...e.attributes].some(a => a.name.startsWith('data-com-onepassword'))).slice(0, 8)
              .map(e => e.tagName.toLowerCase())
          })), 4000)); })()
        """
        note("github login: \(await evaluate(window, probe))")
        await shot(window, "chrome-3-github-login")
        window.close()
        await pause(1)
        exit(0)
    }

    private func evaluate(_ window: BCEFChromeWindow, _ js: String) async -> String {
        await withCheckedContinuation { c in window.evaluate(js) { c.resume(returning: $0 ?? "nil") } }
    }

    private func shot(_ window: BCEFChromeWindow, _ name: String) async {
        let png: Data? = await withCheckedContinuation { c in window.captureScreenshot { c.resume(returning: $0) } }
        try? png?.write(to: directory.appending(path: "\(name).png"))
    }

    private func note(_ line: String) {
        print("[chrome-check] \(line)")
        let url = directory.appending(path: "report.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
