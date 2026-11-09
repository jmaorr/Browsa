import AppKit
import SwiftUI
import BrowserCore
import Extensibility

/// SpikeBrowsa: the real Browsa Mac UI over mock data, with a control channel so Claude can drive
/// it precisely. Compiled only into the SpikeBrowsa target (the `SPIKE` flag); Browsa never sees it.
///
/// - Its own bundle ID (`com.orriginal.browsa.spike`), so its sandbox container, defaults, history
///   and website data are separate from the daily driver's.
/// - Mock dev servers on 47940–47943 that Radar lists and that serve real pages.
/// - Seeded Notes and a scripted agent that calls Browsa's real MCP tools.
/// - The control channel on `127.0.0.1:47930`; see `Spike/README.md` and `tools/spikectl`.
@MainActor
enum SpikeHarness {
    static let controlPort = UInt16((Bundle.main.object(forInfoDictionaryKey: "SpikeControlPort") as? NSNumber)?.intValue ?? 47930)

    private static var servers: [Int: SpikeHTTPServer] = [:]
    private static var control: SpikeHTTPServer?
    private weak static var delegate: AppDelegate?
    private static let defaults = UserDefaults.standard

    /// Before the library loads: honour a reset, swap in mock data, skip the intro.
    static func willMakeLibrary() {
        let env = ProcessInfo.processInfo.environment
        if defaults.bool(forKey: "spikeResetOnLaunch") || env["SPIKE_RESET"] == "1" {
            if let id = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: id) }
            try? FileManager.default.removeItem(at: Library.defaultSnapshotURL().deletingLastPathComponent())
            try? FileManager.default.removeItem(at: HistoryStore.defaultFileURL())
        }
        RadarSample.servers = SpikeMocks.servers
        if env["SPIKE_WELCOME"] != "1" { Preferences.hasSeenWelcome = true }
        if defaults.object(forKey: "agentsEnabled") == nil { defaults.set(true, forKey: "agentsEnabled") }
    }

    static func start(delegate: AppDelegate) {
        self.delegate = delegate
        for s in SpikeMocks.servers where s.isUp { startMock(s.port) }
        SpikeInput.watchMenus()
        let control = SpikeHTTPServer(port: controlPort) { await route($0) }
        control.start()
        self.control = control
        NSLog("SpikeBrowsa: control channel on http://127.0.0.1:\(controlPort)")

        Task {
            let library = delegate.library
            while library.windows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            fakeRestarts(library)
            if !defaults.bool(forKey: "spikeSeeded") {
                seed(library)
                defaults.set(true, forKey: "spikeSeeded")
            }
            try? await Task.sleep(for: .seconds(2))
            _ = await runScenario("history", delay: 0)
        }
    }

    private static func startMock(_ port: Int) {
        guard servers[port] == nil else { return }
        let server = SpikeHTTPServer(port: UInt16(port)) { request in
            if request.path == "/favicon.ico" { return HTTPResponse(status: 404, body: "") }
            return .html(SpikeMocks.page(port: port, path: request.path))
        }
        server.start()
        servers[port] = server
    }

    private static func stopMock(_ port: Int) {
        servers.removeValue(forKey: port)?.stop()
    }

    /// Restart takes a moment and then the server is back, as a dev script would be.
    private static func fakeRestarts(_ library: Library) {
        RadarStore.shared.restartHandler = { [weak library] s in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard let library else { return }
                startMock(s.port)
                withAnimation(Motion.spring) { RadarStore.shared.set(port: s.port, up: true, in: library) }
            }
        }
    }

    /// First launch (and after a reset): tabs on the mock servers, notes on their pages.
    private static func seed(_ library: Library) {
        for note in SpikeMocks.notes() { _ = library.margin.add(note) }
        let spaces = library.regularSpaces
        let personal = spaces[0]
        _ = library.insertTab(url: SpikeMocks.url(47943), in: personal, source: .link)
        _ = library.insertTab(url: SpikeMocks.url(47941), in: personal, source: .link)
        let shop = library.insertTab(url: SpikeMocks.url(47940, "/checkout"), in: personal, source: .link)
        if spaces.count > 1 {
            _ = library.insertTab(url: SpikeMocks.url(47940, "/cart"), in: spaces[1], source: .link)
        }
        if let window = library.activeWindow {
            window.selectSpace(personal)
            window.select(shop)
        }
        library.scheduleSave()
    }

    // MARK: Agents

    /// Runs a scripted agent session through Browsa's real MCP toolbox.
    static func runScenario(_ name: String, delay: Double) async -> [String: Any] {
        guard let library = delegate?.library else { return ["ok": false, "error": "Not ready"] }
        guard let (agent, steps) = SpikeMocks.scenario(name) else { return ["ok": false, "error": "No scenario \(name)"] }
        var results: [[String: Any]] = []
        for step in steps {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            results.append(await callTool(step.tool, args: step.args, agent: agent, library: library))
        }
        return ["ok": true, "agent": agent, "results": results]
    }

    static func callTool(_ tool: String, args: [String: Any], agent: String, library: Library) async -> [String: Any] {
        let toolbox = library.agents.toolbox
        let session = "spike-" + agent
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                         "params": ["protocolVersion": AgentToolbox.protocolVersion, "capabilities": [:] as [String: Any],
                                                    "clientInfo": ["name": agent, "version": "mock"]]]
        _ = await toolbox.handle(try! JSONSerialization.data(withJSONObject: initialize), session: session)
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]
        guard let reply = await toolbox.handle(try! JSONSerialization.data(withJSONObject: call), session: session),
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return ["tool": tool, "reply": NSNull()] }
        // Screenshots come back as base64; keep the reply small.
        var result = json["result"] as? [String: Any] ?? json
        if var content = result["content"] as? [[String: Any]] {
            for i in content.indices where content[i]["data"] != nil { content[i]["data"] = "<\((content[i]["data"] as? String)?.count ?? 0) chars>" }
            result["content"] = content
        }
        return ["tool": tool, "result": result]
    }

    // MARK: Control channel

    private static func route(_ r: SpikeHTTPServer.Request) async -> HTTPResponse {
        // Pages can reach localhost, but always send an Origin; the CLI doesn't.
        if let origin = r.headers["origin"], !origin.hasPrefix("http://127.0.0.1"), !origin.hasPrefix("http://localhost:\(controlPort)") {
            return .error("Forbidden", status: 403)
        }
        guard let delegate, let library = Optional(delegate.library) else { return .error("Not ready", status: 503) }
        let j = r.json
        func num(_ k: String) -> Double? { (j[k] as? NSNumber)?.doubleValue ?? r.query[k].flatMap(Double.init) }
        func str(_ k: String) -> String? { j[k] as? String ?? r.query[k] }
        let mods = SpikeInput.flags(j["mods"] as? [String] ?? (str("mods")?.split(separator: ",").map(String.init) ?? []))

        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/health"):
            return .json(["ok": true, "app": "SpikeBrowsa", "routes": routes])
        case ("GET", "/state"):
            return .json(state(library))
        case ("GET", "/window"):
            return .json(windowInfo() ?? ["error": "No window"])
        case ("GET", "/tree"):
            SpikeInput.debugAttributes = r.query["debug"] == "1"
            return .json(SpikeInput.tree(maxDepth: Int(num("depth") ?? 40)))
        case ("GET", "/find"), ("POST", "/find"):
            let found = SpikeInput.find(str("text") ?? "", role: str("role"))
            return .json(found.prefix(30).map { f in
                ["label": SpikeInput.label(f.element) ?? "",
                 "role": SpikeInput.role(f.element) ?? "",
                 "frame": [Int(f.frame.minX), Int(f.frame.minY), Int(f.frame.width), Int(f.frame.height)]] as [String: Any]
            })
        case ("POST", "/click"):
            guard let x = num("x"), let y = num("y") else { return .error("Give x and y in window points") }
            await SpikeInput.click(x: x, y: y, count: Int(num("count") ?? 1), right: j["right"] as? Bool ?? false, flags: mods)
            return .ok
        case ("POST", "/press"):
            guard let text = str("text") else { return .error("Give text: a label, title or identifier") }
            let found = SpikeInput.find(text, role: str("role"))
            let index = Int(num("index") ?? 0)
            guard found.indices.contains(index) else { return .error("Nothing matches \"\(text)\" (\(found.count) found)", status: 404) }
            let how = await SpikeInput.press(found[index])
            let f = found[index].frame
            return .json(["ok": true, "how": how, "matches": found.count, "frame": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)]])
        case ("POST", "/hover"):
            guard let x = num("x"), let y = num("y") else { return .error("Give x and y") }
            SpikeInput.hover(x: x, y: y)
            return .ok
        case ("POST", "/drag"):
            guard let from = j["from"] as? [Double], let to = j["to"] as? [Double], from.count == 2, to.count == 2 else {
                return .error("Give from: [x, y] and to: [x, y]")
            }
            await SpikeInput.drag(from: (from[0], from[1]), to: (to[0], to[1]), steps: Int(num("steps") ?? 12), flags: mods)
            return .ok
        case ("POST", "/scroll"):
            guard let x = num("x"), let y = num("y") else { return .error("Give x and y") }
            SpikeInput.scroll(x: x, y: y, dx: num("dx") ?? 0, dy: num("dy") ?? 0)
            return .ok
        case ("POST", "/type"):
            guard let text = str("text") else { return .error("Give text") }
            await SpikeInput.type(text)
            return .ok
        case ("POST", "/key"):
            guard let key = str("key") else { return .error("Give key, like \"k\", \"return\", \"escape\", \"left\"") }
            SpikeInput.key(key, flags: mods)
            return .ok
        case ("POST", "/do"):
            return await perform(str("action") ?? "", j, library: library)
        case ("POST", "/agent/run"):
            let name = str("scenario") ?? "fix-notes"
            let delay = num("delay") ?? 1.2
            if j["wait"] as? Bool == false {
                Task { _ = await runScenario(name, delay: delay) }
                return .json(["ok": true, "started": name])
            }
            return .json(await runScenario(name, delay: delay))
        case ("POST", "/agent/call"):
            guard let tool = str("tool") else { return .error("Give tool, and args") }
            return .json(await callTool(tool, args: j["args"] as? [String: Any] ?? [:], agent: str("agent") ?? "Claude Code", library: library))
        case ("POST", "/reset"):
            defaults.set(true, forKey: "spikeResetOnLaunch")
            defaults.synchronize()
            Task { try? await Task.sleep(for: .milliseconds(200)); exit(0) }
            return .json(["ok": true, "note": "Quitting; the next launch starts from fresh mock data"])
        default:
            return .error("No route \(r.method) \(r.path)", status: 404)
        }
    }

    private static let routes = [
        "GET /state", "GET /window", "GET /tree?depth=", "GET /find?text=&role=",
        "POST /click {x,y,count?,right?,mods?}", "POST /press {text,role?,index?}", "POST /hover {x,y}",
        "POST /drag {from,to,steps?}", "POST /scroll {x,y,dy,dx?}", "POST /type {text}", "POST /key {key,mods?}",
        "POST /do {action,…}", "POST /agent/run {scenario,delay?,wait?}", "POST /agent/call {tool,args,agent?}", "POST /reset",
    ]

    /// App-level actions that would be fiddly to click: layout, appearance, window size.
    private static func perform(_ action: String, _ j: [String: Any], library: Library) async -> HTTPResponse {
        guard let browser = library.activeWindow else { return .error("No window", status: 503) }
        switch action {
        case "newTab":
            browser.newTab(url: (j["url"] as? String).flatMap(URL.init(string:)))
        case "selectSpace":
            guard let name = j["name"] as? String, let space = library.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                return .error("No space named that; spaces: \(library.spaces.map(\.name))")
            }
            browser.selectSpace(space)
        case "selectTab":
            guard let n = j["index"] as? Int, browser.orderedTabs.indices.contains(n) else { return .error("Give index into the current space's tabs") }
            browser.select(browser.orderedTabs[n])
        case "panel":
            withAnimation(Motion.dock) { browser.panel = j["tool"] as? String }
        case "toggleSidebar":
            browser.toggleSidebar()
        case "toast":
            browser.showToast(j["text"] as? String ?? "Hello from SpikeBrowsa")
        case "appearance":
            switch j["mode"] as? String {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        case "resize":
            guard let window = SpikeInput.window, let w = j["width"] as? Double, let h = j["height"] as? Double else { return .error("Give width and height") }
            var f = window.frame
            f.origin.y += f.height - h
            f.size = CGSize(width: w, height: h)
            window.setFrame(f, display: true, animate: false)
        case "front":
            NSApp.activate()
            SpikeInput.window?.makeKeyAndOrderFront(nil)
        case "radarStop", "radarStart":
            guard let port = j["port"] as? Int, RadarStore.shared.servers.contains(where: { $0.port == port }) else {
                return .error("Give port, one of \(RadarStore.shared.servers.map(\.port))")
            }
            let up = action == "radarStart"
            up ? startMock(port) : stopMock(port)
            withAnimation(Motion.spring) { RadarStore.shared.set(port: port, up: up, in: library) }
        case "radarAdd":
            // A server starting: the docs site on 47944.
            guard !RadarStore.shared.servers.contains(where: { $0.port == SpikeMocks.extraServer.port }) else { return .ok }
            startMock(SpikeMocks.extraServer.port)
            withAnimation(Motion.spring) { RadarStore.shared.servers.append(SpikeMocks.extraServer) }
        case "radarRemove":
            guard let port = j["port"] as? Int else { return .error("Give port") }
            stopMock(port)
            withAnimation(Motion.spring) { RadarStore.shared.servers.removeAll { $0.port == port } }
        case "radarClear":
            for s in RadarStore.shared.servers { stopMock(s.port) }
            withAnimation(Motion.spring) { RadarStore.shared.servers = [] }
        case "radarRestore":
            for s in SpikeMocks.servers where s.isUp { startMock(s.port) }
            withAnimation(Motion.spring) { RadarStore.shared.servers = SpikeMocks.servers }
        case "closeMenus":
            SpikeInput.closeMenus()
        case "pauseAgents":
            (j["paused"] as? Bool ?? true) ? library.agents.stopAll() : library.agents.resume()
        case "clearActivity":
            library.agents.clearActivity()
        default:
            return .error("Actions: radarStop/radarStart {port}, radarAdd, radarRemove {port}, radarClear, radarRestore, newTab {url}, selectSpace {name}, selectTab {index}, panel {tool|null}, toggleSidebar, toast {text}, appearance {mode}, resize {width,height}, front, pauseAgents {paused}, clearActivity")
        }
        return .ok
    }

    private static func windowInfo() -> [String: Any]? {
        guard let window = SpikeInput.window else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        return ["id": window.windowNumber, "isKey": window.isKeyWindow,
                "points": [Int(f.width), Int(f.height)],
                "scale": window.backingScaleFactor,
                // For `screencapture -R`: global, top-left origin.
                "screenRect": [Int(f.minX), Int(primary - f.maxY), Int(f.width), Int(f.height)]]
    }

    private static func state(_ library: Library) -> [String: Any] {
        let b = library.activeWindow
        let spaces = library.spaces.map { s -> [String: Any] in
            ["name": s.name, "selected": s.id == b?.selectedSpaceID,
             "tabs": (s.pinned + s.today).map { t in
                 ["title": t.title, "url": t.url?.absoluteString ?? "", "pinned": s.pinned.contains { $0.id == t.id },
                  "current": t.id == b?.currentTab?.id] as [String: Any]
             }]
        }
        let agents = library.agents!
        return [
            "window": windowInfo() ?? NSNull(),
            "spaces": spaces,
            "panel": b?.panel ?? NSNull(),
            "sidebarDocked": b?.isSidebarDocked ?? false,
            "commandBarOpen": b?.commandBar != nil,
            "menusOpen": SpikeInput.openMenus.map { $0.items.map(\.title) },
            "toast": b?.toast ?? NSNull(),
            "prompt": b?.activePrompt.map { String(describing: $0) } ?? NSNull(),
            "notes": ["open": library.margin.notes.filter { $0.status == .open }.count, "total": library.margin.notes.count],
            "agents": ["enabled": agents.isEnabled, "running": agents.isRunning, "paused": agents.isPaused,
                       "port": Int(AgentBridge.port), "token": agents.token, "connected": agents.connectedAgents,
                       "activity": agents.activity.prefix(10).map { "\($0.caller) \($0.tool): \($0.outcome)" }],
            "radar": RadarSample.servers.map { ["port": $0.port, "project": $0.project, "branch": $0.branch, "up": $0.isUp] },
            "tools": library.workbench.tools.map(\.id),
        ]
    }
}
