#if DEBUG
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility

/// Debug only: with BROWSA_AGENT_GATE_CHECK=<folder>, drives the MCP toolbox the way an agent
/// would, from a fresh library, and checks the gate: the Agent space never asks, your tabs do
/// (inline, in the Agents panel), and Stop ends running calls and asks at once. Saves the window
/// at each ask as PNGs, and exits 1 if a check fails. It opens a window: say so before running it.
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
        let wasEnabled = agents.isEnabled
        agents.isEnabled = true
        _ = await box.handle(Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"Claude Code","version":"2"}}}"#.utf8), session: "s")

        // One of your tabs, on a real site.
        browser.newTab(url: URL(string: "https://example.com")!)
        await pause(4)
        guard let yours = browser.currentTab else { note("no tab"); exit(1) }

        // 1. The Agent space never asks, on any site.
        var r = await call(box, "tab_open", ["url": "https://example.org/", "show": false])
        check(agents.requests.isEmpty && !r.isError, "Agent space opens a site without asking")
        r = await call(box, "page_read", [:])
        check(agents.requests.isEmpty && r.text.contains("Example Domain"), "Agent space reads without asking")

        // 2. With no tab named, an agent gets the Agent space, never your tab.
        let agentTab = agents.agentSpace.today.first?.id.uuidString ?? "none"
        check(r.text.contains(agentTab) && !r.text.contains(yours.id.uuidString), "page_read with no tab reads the Agent space, not yours")

        // 3. The tab list asks; declining still lists the Agent space.
        r = await answering(browser, "ask-your-tabs", allow: false) { await call(box, "tabs_list", [:]) }
        check(!r.text.contains("example.com") && r.text.contains("didn't share"), "declined tab list hides your tabs")

        // 4. Reading one of your tabs asks, even though it's only a read, and asks inline.
        r = await answering(browser, "ask-your-tab", allow: false) { await call(box, "page_read", ["tab": .string(yours.id.uuidString)]) }
        check(r.isError && r.text.contains("declined"), "declined read of your tab is refused")
        r = await answering(browser, nil, allow: true) { await call(box, "page_read", ["tab": .string(yours.id.uuidString)]) }
        check(r.text.contains("Example Domain"), "allowed tab can be read")
        r = await call(box, "page_read", ["tab": .string(yours.id.uuidString)])
        check(agents.requests.isEmpty && !r.isError, "allowed once, then no more asks for that tab")

        // 5. Two calls on the same tab share one ask.
        browser.newTab(url: URL(string: "https://example.net")!)
        await pause(3)
        let other = browser.currentTab!
        let a = Task { await call(box, "page_read", ["tab": .string(other.id.uuidString)]) }
        let b = Task { await call(box, "page_screenshot", ["tab": .string(other.id.uuidString)]) }
        while agents.requests.isEmpty { await pause(0.1) }
        await pause(0.5)
        check(agents.requests.count == 1, "two calls, one ask")

        // 6. Stop answers the waiting calls and closes the ask at once.
        let started = Date()
        agents.stopAll()
        let ra = await a.value, rb = await b.value
        check(ra.text == AgentToolbox.stoppedMessage && rb.text == AgentToolbox.stoppedMessage && Date().timeIntervalSince(started) < 1
              && agents.requests.isEmpty, "Stop closes the ask and answers every waiting call")
        r = await call(box, "notes_list", [:])
        check(r.text == AgentToolbox.stoppedMessage, "after Stop even reads are refused")

        // 7. Stop ends a running call too.
        agents.resume()
        let slow = Task { await call(box, "page_click", ["selector": "body"]) }
        await pause(0.05)
        agents.stopAll()
        r = await slow.value
        check(r.text == AgentToolbox.stoppedMessage, "Stop answers a running call")
        agents.resume()

        // 8. Files aren't pages for agents, and .local isn't your dev server.
        r = await call(box, "tab_open", ["url": "file:///etc/hosts"])
        check(r.isError, "file: URLs are refused")
        check(!AgentAccess.isLoopback("router.local") && AgentAccess.isLoopback("127.0.0.1"), ".local isn't loopback")

        // A request waiting, for the panel shot.
        agents.forgetGrants()
        _ = Task { await call(box, "page_read", ["tab": .string(other.id.uuidString)]) }
        while agents.requests.isEmpty { await pause(0.1) }
        await pause(1)
        if let window = browser.nsWindow { save(window, nil, "agents-panel-asking") }
        agents.stopAll()
        agents.resume()

        // The Agents panel after all that.
        await pause(1)
        browser.selectSpace(agents.agentSpace)
        await pause(1.5)
        if let window = browser.nsWindow { save(window, nil, "agents-panel") }
        note(Self.failures == 0 ? "all checks passed" : "\(Self.failures) failed")
        agents.isEnabled = wasEnabled
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

    /// Runs a call, waits for its ask in the Agents panel, saves the window, and answers.
    private func answering(_ browser: Browser, _ shot: String?, allow: Bool,
                           _ work: @escaping @MainActor () async -> Reply) async -> Reply {
        let agents: AgentBridge = browser.library.agents
        let task = Task { await work() }
        var waited = 0.0
        while agents.requests.isEmpty, waited < 10 { await pause(0.1); waited += 0.1 }
        guard let request = agents.requests.first else { note("expected an ask, got none"); Self.failures += 1; return await task.value }
        check(browser.activePrompt == nil && browser.panel == "agents", "the ask is inline in the Agents panel, no popup")
        await pause(0.8)
        if let shot, let window = browser.nsWindow { save(window, nil, shot) }
        agents.answer(request.id, allow: allow)
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
