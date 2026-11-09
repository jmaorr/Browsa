import SwiftUI
import Extensibility

/// Watch a Demo: a scripted agent plans a dinner party on Supper, Browsa's demo site, through the
/// same MCP tools a real agent uses. No agent or account needed, and it always goes the same way.
@MainActor @Observable
final class AgentDemo {
    static let agentName = "Browsa Demo"

    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Supper, served by the agent endpoint on this Mac.
    static var url: URL { URL(string: "http://127.0.0.1:\(AgentBridge.port)/demo")! }

    /// What to give your own agent, to see it do the same thing its own way.
    static var prompt: String {
        "Use Browsa to plan a dinner for 6 at \(url.absoluteString). One guest is vegetarian, and keep it under $80. "
            + "Fill the basket, choose Saturday evening delivery, and leave me a note on the page with the plan. Don't place the order."
    }

    private struct Step {
        let tool: String
        let args: [String: Any]
        var pause: Double = 1.4
    }

    private var steps: [Step] {
        let page = Self.url.absoluteString
        return [
            Step(tool: "page_read", args: [:], pause: 1.8),
            Step(tool: "page_type", args: ["selector": "#guests", "text": "6"]),
            Step(tool: "page_click", args: ["selector": "#add-risotto"]),
            Step(tool: "page_click", args: ["selector": "#add-chicken"]),
            Step(tool: "page_click", args: ["selector": "#add-burrata"]),
            Step(tool: "page_click", args: ["selector": "#swap-parmesan"], pause: 1.8),
            Step(tool: "page_click", args: ["selector": "#slot-sat-evening"]),
            Step(tool: "page_screenshot", args: [:]),
            Step(tool: "notes_add", args: ["url": page, "quote": "Your menu", "body":
                "Dinner for 6, $79.20 all in: Charred Leek & Lemon Risotto (vegetarian), Herb-Roast Chicken Thighs, and Blistered Tomato & Burrata. Delivery Saturday 5–7 pm. Press Place order when you're happy."]),
            Step(tool: "notes_add", args: ["url": page, "selector": "#ingredient-parmesan", "body":
                "Swapped the Parmesan for a vegetarian hard cheese: traditional Parmesan is made with animal rennet."], pause: 0.6),
        ]
    }

    /// Runs the demo in `window`: opens Supper in the Agent space and follows along.
    func start(bridge: AgentBridge, in window: Browser) {
        guard !isRunning else { return }
        if !bridge.isEnabled { bridge.isEnabled = true }
        if bridge.isPaused { bridge.resume() }
        isRunning = true
        // A fresh run each time: the last demo's notes and Supper tab go first.
        let key = MarginStore.pageKey(Self.url)
        for note in bridge.margin.notes(on: Self.url) where note.author == .agent(Self.agentName) { bridge.margin.delete(note.id) }
        for tab in bridge.allTabs where tab.url.map(MarginStore.pageKey) == key { window.close(tab) }
        task = Task { [weak self] in
            defer { self?.isRunning = false }
            let session = "browsa-demo"
            _ = await Self.call(bridge, session: session, method: "initialize",
                                params: ["protocolVersion": AgentToolbox.protocolVersion, "capabilities": [:] as [String: Any],
                                         "clientInfo": ["name": Self.agentName, "version": "1"]])
            _ = await Self.call(bridge, session: session, method: "tools/call",
                                params: ["name": "tab_open", "arguments": ["url": Self.url.absoluteString, "show": false]])
            bridge.watch(in: window)
            try? await Task.sleep(for: .seconds(1.2))
            for step in self?.steps ?? [] {
                guard !Task.isCancelled, !bridge.isPaused else { return }
                _ = await Self.call(bridge, session: session, method: "tools/call", params: ["name": step.tool, "arguments": step.args])
                try? await Task.sleep(for: .seconds(step.pause))
            }
            // The reveal: its notes, pinned to the page, scrolled to the menu where both are pinned.
            if let tab = bridge.tab(nil) { let page = bridge.controller(for: tab).page!
                _ = try? await page.evaluate("const m = document.querySelector('#menu'); if (getComputedStyle(m).position === 'sticky') scrollTo({ top: 0, behavior: 'smooth' }); else m.scrollIntoView({ behavior: 'smooth', block: 'start' }); return true", inWorld: "browsa.agent")
            }
            withAnimation(Motion.dock) { window.showPanel("notes") }
        }
    }

    func cancel() { task?.cancel() }

    private static func call(_ bridge: AgentBridge, session: String, method: String, params: [String: Any]) async -> Data? {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return await bridge.toolbox.handle(body, session: session)
    }
}
