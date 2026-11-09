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
/// - a per-site **ask first** gate and a **Stop** button the browser owns, not the agent.
@MainActor @Observable
final class AgentBridge {
    /// 47913, unless Info.plist says otherwise (SpikeBrowsa uses its own, so both can run).
    static let port = UInt16((Bundle.main.object(forInfoDictionaryKey: "BrowsaAgentPort") as? NSNumber)?.intValue ?? 47913)

    var isEnabled: Bool {
        didSet { Preferences.agentsEnabled = isEnabled; isEnabled ? start() : stop() }
    }
    /// Stop: every call that changes something is refused until resumed.
    var isPaused = false
    private(set) var activity: [AgentActivity] = []
    /// Sites agents may act on without asking, by host. "Ask once per site" fills it.
    private(set) var trustedHosts: Set<String>
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
            await self?.authorize(tool, args: args, caller: caller) ?? false
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
        Preferences.agentTrustedHosts = Array(trustedHosts)
    }

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

    /// The tab an agent means: the one it named, else the newest in the Agent space, else what's on screen.
    func tab(_ id: String?) -> BrowserTab? {
        if let id, let uuid = UUID(uuidString: id) { return library.tab(id: uuid) }
        return agentSpace.today.first ?? library.activeWindow?.currentTab
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

    private func authorize(_ tool: AgentTool, args: JSONValue, caller: AgentCaller) async -> Bool {
        if isPaused { return false }
        if !connectedAgents.contains(caller.name) { connectedAgents.append(caller.name) }
        // Plugins' own tools and notes don't touch a page.
        guard tool.pluginID == nil, !tool.name.hasPrefix("notes_") else { return true }
        let host = tab(args["tab"]?.string)?.url?.host() ?? args["url"]?.string.flatMap { URL(string: $0)?.host() } ?? ""
        if host.isEmpty || trustedHosts.contains(host) || Self.isLocal(host) { return true }
        guard let window = library.activeWindow else { return false }
        let answer = await window.askForAgent(.agent(caller: caller.name, action: tool.title, host: host))
        if answer == .ok {
            trustedHosts.insert(host)
            Preferences.agentTrustedHosts = Array(trustedHosts)
            return true
        }
        return false
    }

    /// Your own dev servers: agents can always work on them.
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
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
