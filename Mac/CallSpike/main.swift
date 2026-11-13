// Spike: Google Meet (or any call site) in an embedded Chromium (CEF, Alloy style) inside a Browsa-like
// window, next to a WebKit tab, to see whether Chromium's own call audio (echo cancellation) fixes calls
// and what a "call tab" would cost. Not part of Browsa.
import AppKit
import WebKit

@MainActor
final class Spike: NSObject, NSApplicationDelegate, BCEFBrowserDelegate {
    var window: NSWindow!
    let content = NSView()
    var chromium: BCEFBrowser!
    let webkit = WKWebView()
    let address = NSTextField()
    var tabs: [NSButton] = []
    var current = 0
    var recorderSource: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browsa Call Spike").path
        guard BCEFRuntime.start(withCachePath: cache) else { NSLog("[cef-call] CEF failed to start"); NSApp.terminate(nil); return }
        NSLog("[cef-call] CEF %@", BCEFRuntime.version())
        let start = ProcessInfo.processInfo.environment["BROWSA_CALL_URL"] ?? "https://meet.google.com/"
        chromium = BCEFBrowser(url: start, incognito: false)
        chromium.delegate = self
        webkit.load(URLRequest(url: URL(string: "https://example.com/")!))

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Browsa Call Spike"
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        address.placeholderString = "Address"
        address.target = self; address.action = #selector(go)
        sidebar.addArrangedSubview(address)
        for (i, name) in ["Call (Chromium)", "Page (WebKit)"].enumerated() {
            let b = NSButton(title: name, target: self, action: #selector(pick(_:)))
            b.tag = i; b.bezelStyle = .recessed; b.setButtonType(.pushOnPushOff)
            tabs.append(b); sidebar.addArrangedSubview(b)
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 900)
        sidebar.autoresizingMask = [.height]
        address.widthAnchor.constraint(equalToConstant: 200).isActive = true
        content.frame = NSRect(x: 220, y: 0, width: 1180, height: 900)
        content.autoresizingMask = [.width, .height]
        root.addSubview(sidebar); root.addSubview(content)
        window.contentView = root
        window.center(); window.makeKeyAndOrderFront(nil)
        buildMenus()
        show(0)
        // Recording for the echo check: BROWSA_CALL_RECORD=<file.jsonl> saves 10 s chunks of what the call
        // sends and receives (see recorder.js).
        if let out = ProcessInfo.processInfo.environment["BROWSA_CALL_RECORD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                if let url = Bundle.main.url(forResource: "recorder", withExtension: "js"), let js = try? String(contentsOf: url, encoding: .utf8) {
                    chromium.addScript(onNewDocument: js)
                    recorderSource = js
                    chromium.reload()
                }
            }
            FileManager.default.createFile(atPath: out, contents: nil)
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.chromium.evaluate("window.__echoRec ? window.__echoRec.take() : null") { json in
                        guard let json, let h = FileHandle(forWritingAtPath: out) else { return }
                        h.seekToEndOfFile(); h.write((json + "\n").data(using: .utf8)!); try? h.close()
                    }
                }
            }
        }
        // Tab-switch check without clicking: BROWSA_CALL_SWITCH=<seconds> flips tabs every N seconds.
        if let s = ProcessInfo.processInfo.environment["BROWSA_CALL_SWITCH"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.show(1 - (self?.current ?? 0)) } }
        }
    }

    // Like Browsa: the hidden tab's view leaves the window.
    func show(_ i: Int) {
        current = i
        content.subviews.forEach { $0.removeFromSuperview() }
        let v: NSView = i == 0 ? chromium.view : webkit
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = content.bounds
        v.autoresizingMask = [.width, .height]
        content.addSubview(v)
        for (k, b) in tabs.enumerated() { b.state = k == i ? .on : .off }
        NSLog("[cef-call] showing tab %d", i)
    }
    @objc func pick(_ b: NSButton) { show(b.tag) }
    @objc func newMeeting() { show(0); chromium.loadURL("https://meet.new") }
    @objc func focusAddress() { window.makeFirstResponder(address); address.selectText(nil) }

    // Standard menus: Edit's items go to whatever has focus (the Chromium page handles cut:, copy:,
    // paste:, selectAll:, undo: and redo: itself), so Cmd-C/V/X/A/Z work in pages and the address field.
    func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) { let top = NSMenuItem(); let m = NSMenu(title: title); items.forEach(m.addItem); top.submenu = m; main.addItem(top) }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        menu("Browsa Call Spike", [item("Quit Browsa Call Spike", #selector(NSApplication.terminate(_:)), "q")])
        menu("File", [item("New Meeting", #selector(newMeeting), "n", target: self),
                      item("Open Location…", #selector(focusAddress), "l", target: self)])
        menu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                      item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                      item("Paste", #selector(NSText.paste(_:)), "v"),
                      item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
                      item("Select All", #selector(NSText.selectAll(_:)), "a")])
        NSApp.mainMenu = main
    }
    @objc func go() {
        var s = address.stringValue
        if !s.contains("://") { s = "https://" + s }
        if current == 0 { chromium.loadURL(s) } else { _ = webkit.load(URLRequest(url: URL(string: s)!)) }
    }
    func applicationWillTerminate(_ notification: Notification) { BCEFRuntime.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // BCEFBrowserDelegate
    func browserAddressChanged(_ url: String) { if current == 0 { address.stringValue = url } }
    func browserTitleChanged(_ title: String) { tabs.first?.title = "Call: " + title.prefix(24) }
    func browserProgressChanged(_ progress: Double) {}
    func browserLoadingChanged(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func browserLoadEnded(_ url: String, status: Int32) {
        NSLog("[cef-call] loaded %@ (%d)", url, status)
        // Belt and braces: also run the recorder once the page has loaded, and say whether it was there.
        if let js = recorderSource {
            chromium.evaluate("(() => { const had = !!window.__echoRec; " + js + "; return { had, now: !!window.__echoRec }; })()") { NSLog("[cef-call] recorder check %@", $0 ?? "nil") }
        }
    }
    func browserLoadFailed(_ url: String, code: Int32, text: String) { NSLog("[cef-call] failed %@ %d %@", url, code, text) }
    func browserWantsNewTab(_ url: String, foreground: Bool) { chromium.loadURL(url) }
    func browserShouldNavigate(_ url: String, userGesture: Bool) -> Bool { true }
    func browserFindResult(_ count: Int32, active: Int32, final: Bool) {}
    func browserDidClose() {}
}

// Spike: NSLog (stderr) to a file, since the system log isn't readable here.
let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Browsa/call-spike.log").path
freopen(logPath, "a", stderr)
let app = BCEFApplication.shared
let spike = Spike()
app.delegate = spike
app.setActivationPolicy(.regular)
app.run()
