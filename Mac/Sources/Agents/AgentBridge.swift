import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Extensibility

/// Something an agent is waiting for you to allow, shown in the Agents panel.
struct AgentRequest: Identifiable, Equatable {
    let id = UUID()
    let caller: String
    let action: String
    let grant: AgentAccess.Grant
    /// For one of your tabs: its title.
    let tabTitle: String?
    let at = Date()
}

/// Lets coding agents (Claude Code, Codex, Cursor…) use Browsa over MCP.
///
/// What an agent gets that a separate automation browser can't give it:
/// - the user's real browser, with an **Agent space** they can watch, signed in as them;
/// - **Margin notes**, the user's feedback pinned to pages, as a shared to-do list;
/// - a gate on every call, reads included: the Agent space is the agent's to drive, and your own
///   tabs ask first, inline in the Agents panel, never as a popup;
/// - a **Stop** button the browser owns, not the agent.
@MainActor @Observable
final class AgentBridge {
    static let port: UInt16 = {
        #if DEBUG
        // The debug checks run beside your everyday Browsa, which holds the usual port.
        if let p = ProcessInfo.processInfo.environment["BROWSA_AGENT_PORT"].flatMap(UInt16.init) { return p }
        #endif
        // SpikeBrowsa sets its own in Info.plist, so it can run beside Browsa too.
        if let p = (Bundle.main.object(forInfoDictionaryKey: "BrowsaAgentPort") as? NSNumber)?.uint16Value { return p }
        return 47913
    }()
    /// An agent counts as driving for this long after its last call.
    static let idleAfter: TimeInterval = 10 * 60

    var isEnabled: Bool {
        didSet { Preferences.agentsEnabled = isEnabled; isEnabled ? start() : stop() }
    }
    /// After Stop: every call is refused, reads included, until resumed.
    private(set) var isPaused = false
    private(set) var activity: [AgentActivity] = []
    /// Asks waiting for you, oldest first. The Agents panel shows them; nothing pops up.
    private(set) var requests: [AgentRequest] = []
    /// Allowed until Browsa quits: your own tabs, and the list of them.
    private(set) var grants: Set<AgentAccess.Grant> = []
    private(set) var connectedAgents: [String] = []
    /// An agent called in the last few minutes, or is waiting on you. Shows the Agent space.
    private(set) var isDriving = false
    var isRunning: Bool { server?.isRunning ?? false }
    var problem: String? { server?.problem }

    let token: String
    @ObservationIgnored let toolbox: AgentToolbox
    @ObservationIgnored private var server: AgentServer?
    @ObservationIgnored private unowned let library: Library
    /// Calls waiting on each request.
    @ObservationIgnored private var waiting: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    @ObservationIgnored private var lastCall: Date?
    @ObservationIgnored private var idleTimer: Timer?

    /// For Settings: paste into a terminal once.
    var claudeCodeCommand: String {
        "claude mcp add --transport http browsa http://127.0.0.1:\(Self.port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    init(library: Library) {
        self.library = library
        token = Preferences.agentToken
        isEnabled = Preferences.agentsEnabled
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        toolbox = AgentToolbox(serverVersion: version)
        toolbox.authorize = { [weak self] tool, args, caller in
            await self?.authorize(tool, args: args, caller: caller) ?? .deny("Browsa is closing.")
        }
        toolbox.onActivity = { [weak self] entry in self?.record(entry) }
        BrowserAgentTools.register(in: toolbox, bridge: self)
        if isEnabled { start() }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDriving() }
        }
    }

    func start() {
        guard server == nil else { return }
        let toolbox = toolbox
        let server = AgentServer(port: Self.port, token: token) { body, session in
            await toolbox.handle(body, session: session)
        }
        server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Your own tabs agents may use until quit, for Settings.
    var allowedTabCount: Int {
        grants.filter { if case .yourTab = $0 { true } else { false } }.count
    }

    /// Takes back everything allowed so far.
    func forgetGrants() { grants.removeAll() }

    // MARK: Stop

    /// Halts every agent now: running calls answer "stopped" and are cancelled, waiting asks
    /// close as "Don't Allow", Agent space pages stop loading, and nothing runs until Resume.
    func stopAll() {
        isPaused = true
        toolbox.stopAll()
        for id in requests.map(\.id) { answer(id, allow: false) }
        if let space = existingAgentSpace {
            for tab in space.today where tab.isLoading { library.controller(for: tab).page.stopLoading() }
        }
    }

    func resume() { isPaused = false }

    func clearActivity() { activity.removeAll() }

    // MARK: The Agent space

    /// Where agents open pages: its own space, so their tabs never mix with yours.
    var agentSpace: Space {
        if let space = existingAgentSpace { return space }
        let space = library.addSpace()
        space.name = "Agent"
        space.symbol = AgentIdentity.symbol
        Preferences.agentSpaceID = space.id
        library.scheduleSave()
        // It opens on the Agents panel: what's happening, what's waiting on you, and Stop.
        library.windows.forEach { $0.setPanel("agents", for: space, ifUnset: true) }
        return space
    }

    /// The Agent space if there is one, without making it.
    var existingAgentSpace: Space? {
        let space = Preferences.agentSpaceID.flatMap { id in library.regularSpaces.first { $0.id == id } }
        // Made before the icon changed.
        if let space, space.symbol == "sparkles" { space.symbol = AgentIdentity.symbol; library.scheduleSave() }
        return space
    }

    /// The sidebar shows the Agent space only while an agent is driving or has pages open there.
    func showsInSidebar(_ space: Space) -> Bool {
        space.id != Preferences.agentSpaceID || isDriving || !space.allTabs.isEmpty
    }

    /// The tab an agent means: the one it named, else the newest in the Agent space. Never the
    /// tab you happen to be looking at: an agent has to name one of yours, and that asks.
    func tab(_ id: String?) -> BrowserTab? {
        if let id {
            guard let uuid = UUID(uuidString: id), let tab = library.tab(id: uuid), !tab.isPrivate else { return nil }
            return tab
        }
        return existingAgentSpace?.today.first
    }

    func isInAgentSpace(_ tab: BrowserTab) -> Bool {
        guard let id = Preferences.agentSpaceID else { return false }
        return space(of: tab)?.id == id
    }

    func controller(for tab: BrowserTab) -> TabController { library.controller(for: tab) }

    var margin: MarginStore { library.margin }
    var allTabs: [BrowserTab] { library.allTabs.filter { !$0.isPrivate } }
    func space(of tab: BrowserTab) -> Space? { library.space(containing: tab) }

    func openTab(_ url: URL, show: Bool) -> BrowserTab {
        let tab = library.insertTab(url: url, in: agentSpace, source: .link)
        if show, let window = library.activeWindow {
            window.selectSpace(agentSpace)
            window.select(tab)
        }
        return tab
    }

    // MARK: Asking

    /// Every call comes through here, reads included.
    private func authorize(_ tool: AgentTool, args: JSONValue, caller: AgentCaller) async -> AgentToolbox.Verdict {
        if isPaused { return .deny(AgentToolbox.stoppedMessage) }
        if !connectedAgents.contains(caller.name) { connectedAgents.append(caller.name) }
        lastCall = Date()
        updateDriving()
        for grant in grants(for: tool, args: args) {
            let allowed = await ask(grant, caller: caller.name, action: tool.title)
            if isPaused { return .deny(AgentToolbox.stoppedMessage) }
            if !allowed { return .deny("The user declined this in Browsa.") }
        }
        noteWork(tool, args: args, caller: caller.name)
        return .allow
    }

    /// Pages an agent is working on right now, by `MarginStore.pageKey`, for the Notes panel's
    /// "on it" line. A page counts while the agent's last call on it is under `workingFor` old.
    private(set) var workingPages: [String: (agent: String, at: Date)] = [:]
    static let workingFor: TimeInterval = 20

    func working(on url: URL?) -> String? {
        guard let url, let w = workingPages[MarginStore.pageKey(url)], Date().timeIntervalSince(w.at) < Self.workingFor else { return nil }
        return w.agent
    }

    private func noteWork(_ tool: AgentTool, args: JSONValue, caller: String) {
        var url: URL?
        if tool.name.hasPrefix("page_") { url = tab(args["tab"]?.string)?.url }
        if tool.name == "notes_reply" || tool.name == "notes_resolve",
           let id = args["id"]?.string.flatMap(UUID.init(uuidString:)) {
            url = library.margin.note(id).flatMap { URL(string: $0.url) }
        }
        guard let url else { return }
        workingPages[MarginStore.pageKey(url)] = (caller, Date())
    }

    /// What a call touches. Notes and plugins' own tools don't touch a page; tabs_list asks for
    /// itself, since without your tabs it can still list the Agent space.
    private func grants(for tool: AgentTool, args: JSONValue) -> [AgentAccess.Grant] {
        guard tool.pluginID == nil, tool.name.hasPrefix("page_") else { return [] }
        let target = tab(args["tab"]?.string).map {
            AgentAccess.Target(tabID: $0.id, host: $0.url?.host()?.lowercased() ?? "", inAgentSpace: isInAgentSpace($0))
        }
        return AgentAccess.grants(target: target)
    }

    /// Asks once for each thing, however many calls are waiting on it. The ask waits in the
    /// Agents panel, which opens in the window you're using, so it never takes the keyboard.
    func ask(_ grant: AgentAccess.Grant, caller: String, action: String) async -> Bool {
        if grants.contains(grant) { return true }
        if isPaused { return false }
        let request: AgentRequest
        if let existing = requests.first(where: { $0.grant == grant }) {
            request = existing
        } else {
            request = AgentRequest(caller: caller, action: action, grant: grant, tabTitle: title(of: grant))
            requests.append(request)
            updateDriving()
            library.activeWindow?.showAgentsPanel()
        }
        return await withCheckedContinuation { cont in waiting[request.id, default: []].append(cont) }
    }

    /// Answers a request from the Agents panel.
    func answer(_ id: UUID, allow: Bool) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        let request = requests.remove(at: i)
        if allow, !isPaused { grants.insert(request.grant) }
        for cont in waiting.removeValue(forKey: id) ?? [] { cont.resume(returning: allow && !isPaused) }
        updateDriving()
    }

    private func title(of grant: AgentAccess.Grant) -> String? {
        guard case .yourTab(let id, _) = grant else { return nil }
        return library.tab(id: id)?.displayTitle
    }

    private func updateDriving() {
        let now = !requests.isEmpty || toolbox.hasRunningCalls
            || lastCall.map { Date().timeIntervalSince($0) < Self.idleAfter } ?? false
        if now != isDriving { isDriving = now }
    }

    private func record(_ entry: AgentActivity) {
        var entry = entry
        // "tab: 600B939B-…" says nothing to you; the tab's title does.
        if let range = entry.summary.range(of: #"tab: [0-9A-F-]{36}"#, options: .regularExpression),
           let id = UUID(uuidString: String(entry.summary[range].dropFirst(5))) {
            entry.summary.replaceSubrange(range, with: "tab: “\(library.tab(id: id)?.displayTitle ?? "closed tab")”")
        }
        if let i = activity.firstIndex(where: { $0.id == entry.id }) {
            activity[i] = entry
        } else {
            activity.insert(entry, at: 0)
            if activity.count > 200 { activity.removeLast() }
        }
    }
}

extension Preferences {
    static var agentsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "agentsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "agentsEnabled") }
    }

    /// Made once, kept in user defaults (sandboxed to Browsa). Anyone who can read it can already
    /// read your cookies, so the keychain wouldn't add much.
    static var agentToken: String {
        if let t = UserDefaults.standard.string(forKey: "agentToken") { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = "browsa_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(t, forKey: "agentToken")
        return t
    }

    static var agentSpaceID: UUID? {
        get { UserDefaults.standard.string(forKey: "agentSpaceID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "agentSpaceID") }
    }
}
