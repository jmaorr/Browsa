#if DEBUG
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility

/// Debug only: with BROWSA_AGENT_GATE_CHECK=<folder>, drives the MCP toolbox the way an agent
/// would, from a fresh library, and checks the gate: reads of your tabs ask, navigation asks for
/// where it goes, loopback never asks, `.local` does, and Stop ends a call and an ask at once.
/// Saves each ask and the Agents panel as PNGs, and exits 1 if a check fails.
@MainActor
struct AgentGateCheck {
    let directory: URL
    let delegate: AppDelegate
    private static var failures = 0

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser else { note("no window"); exit(1) }
        let agents: AgentBridge = delegate.library.agents
        let box = agents.toolbox
        _ = await box.handle(Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"Claude Code","version":"2"}}}"#.utf8), session: "s")

        // One of your tabs, on a real site.
        browser.newTab(url: URL(string: "https://example.com")!)
        await pause(4)
        guard let yours = browser.currentTab else { note("no tab"); exit(1) }

        // 1. Loopback never asks.
        var r = await call(box, "tab_open", ["url": "http://localhost:9/", "show": false])
        check(browser.activePrompt == nil && !r.isError, "localhost opens without asking")

        // 2. With no tab named and nothing else, an agent gets the Agent space, never your tab.
        let agentTab = agents.agentSpace.today.first?.id.uuidString ?? "none"
        r = await call(box, "page_read", [:])
        check(r.text.contains(agentTab) && !r.text.contains(yours.id.uuidString), "page_read with no tab reads the Agent space, not yours")

        // 3. The tab list asks; declining still lists the Agent space.
        r = await answering(browser, "ask-your-tabs", with: .cancel) { await call(box, "tabs_list", [:]) }
        check(!r.text.contains("example.com") && r.text.contains("didn't share"), "declined tab list hides your tabs")

        // 4. Reading one of your tabs asks, even though it's only a read.
        r = await answering(browser, "ask-your-tab", with: .cancel) { await call(box, "page_read", ["tab": .string(yours.id.uuidString)]) }
        check(r.isError && r.text.contains("declined"), "declined read of your tab is refused")
        r = await answering(browser, nil, with: .ok) { await call(box, "page_screenshot", ["tab": .string(yours.id.uuidString)]) }
        check(!r.text.contains("declined"), "allowed tab can be used")
        r = await call(box, "page_read", ["tab": .string(yours.id.uuidString)])
        check(browser.activePrompt == nil && r.text.contains("Example Domain"), "allowed once, then no more asks for that tab")

        // 5. Navigating from localhost asks for where it's going.
        r = await answering(browser, "ask-site", with: .ok) { await call(box, "page_navigate", ["url": "https://example.org"]) }
        check(!r.isError, "navigation to an allowed site works")
        r = await call(box, "tab_open", ["url": "https://example.org/", "show": false])
        check(browser.activePrompt == nil && !r.isError, "allowed site doesn't ask again this session")

        // 6. .local is not "your dev server".
        r = await answering(browser, nil, with: .cancel) { await call(box, "tab_open", ["url": "http://router.local/", "show": false]) }
        check(r.isError, ".local asks, and declining refuses")

        // 7. Files and scripts aren't pages for agents.
        r = await call(box, "tab_open", ["url": "file:///etc/hosts"])
        check(r.isError, "file: URLs are refused")

        // 8. Stop ends an open ask and everything after it, at once.
        browser.newTab(url: URL(string: "https://example.net")!)
        await pause(3)
        let other = browser.currentTab!
        let pending = Task { await call(box, "page_read", ["tab": .string(other.id.uuidString)]) }
        var waitedForAsk = 0.0
        while browser.activePrompt == nil, waitedForAsk < 10 { await pause(0.1); waitedForAsk += 0.1 }
        let started = Date()
        agents.stopAll()
        r = await pending.value
        check(r.text == AgentToolbox.stoppedMessage && Date().timeIntervalSince(started) < 1 && browser.activePrompt == nil,
              "Stop closes the ask and answers the waiting call")
        r = await call(box, "notes_list", [:])
        check(r.text == AgentToolbox.stoppedMessage, "after Stop even reads are refused")

        // Stop ends a running call too: a slow load.
        agents.resume()
        let slow = Task { await call(box, "page_click", ["selector": "body"]) }
        await pause(0.05)
        agents.stopAll()
        r = await slow.value
        check(r.text == AgentToolbox.stoppedMessage, "Stop answers a running call")
        await pause(0.5)

        // The Agents panel after all that.
        await pause(1)
        browser.panel = "agents"
        await pause(1.5)
        if let window = browser.nsWindow { save(window, nil, "agents-panel") }
        note(Self.failures == 0 ? "all checks passed" : "\(Self.failures) failed")
        exit(Self.failures == 0 ? 0 : 1)
    }

    struct Reply { let isError: Bool; let text: String }

    private func call(_ box: AgentToolbox, _ tool: String, _ args: JSONValue) async -> Reply {
        let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": args]]
        guard let data = try? body.data(), let out = await box.handle(data, session: "s"), let json = try? JSONValue(data: out) else {
            return Reply(isError: true, text: "no reply")
        }
        let text = json["result"]?["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
        Self.last = "\(tool): \(text)"
        return Reply(isError: json["result"]?["isError"]?.bool ?? true, text: text)
    }

    /// Runs a call, waits for its ask, saves it, and answers.
    private func answering(_ browser: Browser, _ shot: String?, with response: EngineDialogResponse,
                           _ work: @escaping @MainActor () async -> Reply) async -> Reply {
        let task = Task { await work() }
        var waited = 0.0
        while browser.activePrompt == nil, waited < 10 { await pause(0.1); waited += 0.1 }
        guard browser.activePrompt != nil else { note("expected an ask, got none"); Self.failures += 1; return await task.value }
        await pause(0.8)
        if let shot, let window = browser.nsWindow { save(window, window.attachedSheet ?? window.sheets.first, shot) }
        browser.answer(response)
        return await task.value
    }

    private static var last = ""
    private func check(_ ok: Bool, _ what: String) {
        if !ok { Self.failures += 1; note("     last reply: \(Self.last.prefix(300).replacingOccurrences(of: "\n", with: " "))") }
        note("\(ok ? "ok  " : "FAIL") \(what)")
    }

    /// The window, with its sheet drawn where it sits.
    private func save(_ window: NSWindow, _ sheet: NSWindow?, _ name: String) {
        guard let view = window.contentView?.superview, let base = image(of: view) else { return }
        let size = view.bounds.size
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        if let sheet, let sv = sheet.contentView?.superview, let top = image(of: sv) {
            let f = sheet.frame, w = window.frame
            top.draw(in: NSRect(x: f.minX - w.minX, y: f.minY - w.minY, width: f.width, height: f.height))
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
    }

    private func image(of view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    private func note(_ line: String) { FileHandle.standardError.write(Data("[gate] \(line)\n".utf8)) }
    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
