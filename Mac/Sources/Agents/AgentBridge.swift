import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Extensibility

/// Lets coding agents (Claude Code, Codex, Cursor…) use Browsa over MCP.
///
/// What an agent gets that a separate automation browser can't give it:
/// - the user's real browser, with an **Agent space** they can watch, signed in as them;
/// - **Margin notes**, the user's feedback pinned to pages, as a shared to-do list;
/// - an **ask first** gate on every call, reads included, judged by the tab and site it touches,
///   and a **Stop** button the browser owns, not the agent.
@MainActor @Observable
final class AgentBridge {
    static let port: UInt16 = 47913

    var isEnabled: Bool {
        didSet { Preferences.agentsEnabled = isEnabled; isEnabled ? start() : stop() }
    }
    /// After Stop: every call is refused, reads included, until resumed.
    private(set) var isPaused = false
    private(set) var activity: [AgentActivity] = []
    /// Sites agents may always use without asking, by host ("Always allow" on the ask).
    private(set) var trustedHosts: Set<String>
    /// Allowed until Browsa quits: sites, your own tabs, and the list of your tabs.
    private(set) var sessionGrants: Set<AgentAccess.Grant> = []
    /// Asks on screen or queued, so calls that need the same thing share one.
    @ObservationIgnored private var pendingAsks: [AgentAccess.Grant: Task<Bool, Never>] = [:]
    private(set) var connectedAgents: [String] = []
    var isRunning: Bool { server?.isRunning ?? false }
    var problem: String? { server?.problem }

    let token: String
    @ObservationIgnored let toolbox: AgentToolbox
    @ObservationIgnored private var server: AgentServer?
    @ObservationIgnored private unowned let library: Library

    /// For Settings: paste into a terminal once.
    var claudeCodeCommand: String {
        "claude mcp add --transport http browsa http://127.0.0.1:\(Self.port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    init(library: Library) {
        self.library = library
        token = Preferences.agentToken
        trustedHosts = Set(Preferences.agentTrustedHosts)
        isEnabled = Preferences.agentsEnabled
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        toolbox = AgentToolbox(serverVersion: version)
        toolbox.authorize = { [weak self] tool, args, caller in
            await self?.authorize(tool, args: args, caller: caller) ?? .deny("Browsa is closing.")
        }
        toolbox.onActivity = { [weak self] entry in self?.record(entry) }
        BrowserAgentTools.register(in: toolbox, bridge: self)
        if isEnabled { start() }
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

    func forget(host: String) {
        trustedHosts.remove(host)
        sessionGrants.remove(.site(host))
        Preferences.agentTrustedHosts = Array(trustedHosts)
    }

    /// Sites allowed until quit, for Settings.
    var sessionHosts: [String] {
        sessionGrants.compactMap { if case .site(let h) = $0, !trustedHosts.contains(h) { h } else { nil } }.sorted()
    }

    /// Your own tabs agents may use until quit, for Settings.
    var sessionTabCount: Int {
        sessionGrants.filter { if case .yourTab = $0 { true } else { false } }.count
    }

    /// Takes back everything allowed for this session (not the "always" sites).
    func forgetSession() { sessionGrants.removeAll() }

    // MARK: Stop

    /// Halts every agent now: running calls answer "stopped" and are cancelled, open asks close
    /// as "Don't Allow", and nothing runs again until Resume.
    func stopAll() {
        isPaused = true
        toolbox.stopAll()
        for task in pendingAsks.values { task.cancel() }
        pendingAsks.removeAll()
        library.windows.forEach { $0.cancelAgentPrompts() }
        for tab in agentSpace.today where tab.isLoading { library.controller(for: tab).page.stopLoading() }
    }

    func resume() { isPaused = false }

    func clearActivity() { activity.removeAll() }

    // MARK: The Agent space

    /// Where agents open pages: its own space, so their tabs never mix with yours.
    var agentSpace: Space {
        if let id = Preferences.agentSpaceID, let space = library.regularSpaces.first(where: { $0.id == id }) {
            return space
        }
        let space = library.addSpace()
        space.name = "Agent"
        space.symbol = "sparkles"
        Preferences.agentSpaceID = space.id
        library.scheduleSave()
        return space
    }

    /// The tab an agent means: the one it named, else the newest in the Agent space. Never the
    /// tab you happen to be looking at: an agent has to name one of yours, and that asks.
    func tab(_ id: String?) -> BrowserTab? {
        if let id {
            guard let uuid = UUID(uuidString: id), let tab = library.tab(id: uuid), !tab.isPrivate else { return nil }
            return tab
        }
        return agentSpace.today.first
    }

    func isInAgentSpace(_ tab: BrowserTab) -> Bool { space(of: tab)?.id == agentSpace.id }

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
        for grant in grants(for: tool, args: args) where !isAllowed(grant) {
            let allowed = await ask(grant, caller: caller.name, action: tool.title)
            if isPaused { return .deny(AgentToolbox.stoppedMessage) }
            if !allowed { return .deny("The user declined this in Browsa.") }
        }
        return .allow
    }

    /// What a call touches. Notes and plugins' own tools don't touch a page; tabs_list asks for
    /// itself, since without your tabs it can still list the Agent space.
    private func grants(for tool: AgentTool, args: JSONValue) -> [AgentAccess.Grant] {
        guard tool.pluginID == nil, tool.name.hasPrefix("page_") || tool.name == "tab_open" else { return [] }
        let target: AgentAccess.Target? = tool.name == "tab_open" ? nil : tab(args["tab"]?.string).map {
            AgentAccess.Target(tabID: $0.id, host: $0.url?.host()?.lowercased() ?? "", inAgentSpace: isInAgentSpace($0))
        }
        let destination = tool.name == "tab_open" || tool.name == "page_navigate" ? AgentAccess.host(of: args["url"]?.string) : nil
        return AgentAccess.grants(target: target, destination: destination)
    }

    func isAllowed(_ grant: AgentAccess.Grant) -> Bool {
        if sessionGrants.contains(grant) { return true }
        if case .site(let host) = grant { return trustedHosts.contains(host) }
        return false
    }

    /// Asks once for each thing, however many calls are waiting on it.
    func ask(_ grant: AgentAccess.Grant, caller: String, action: String) async -> Bool {
        if isAllowed(grant) { return true }
        if isPaused { return false }
        if let pending = pendingAsks[grant] { return await pending.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self, let window = library.activeWindow else { return false }
            let answer = await window.askForAgent(.agent(AgentAsk(caller: caller, action: action, grant: grant, tabTitle: title(of: grant))))
            guard !Task.isCancelled, !isPaused else { return false }
            switch answer {
            case .ok:
                sessionGrants.insert(grant)
                return true
            case .text(AgentAsk.always):
                sessionGrants.insert(grant)
                if case .site(let host) = grant {
                    trustedHosts.insert(host)
                    Preferences.agentTrustedHosts = Array(trustedHosts)
                }
                return true
            default:
                return false
            }
        }
        pendingAsks[grant] = task
        let allowed = await task.value
        if pendingAsks[grant] == task { pendingAsks[grant] = nil }
        return allowed
    }

    private func title(of grant: AgentAccess.Grant) -> String? {
        guard case .yourTab(let id, _) = grant else { return nil }
        return library.tab(id: id)?.displayTitle
    }

    private func record(_ entry: AgentActivity) {
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

    static var agentTrustedHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: "agentTrustedHosts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "agentTrustedHosts") }
    }

    static var agentSpaceID: UUID? {
        get { UserDefaults.standard.string(forKey: "agentSpaceID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "agentSpaceID") }
    }
}
