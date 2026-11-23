import AppKit
import Foundation
import Observation

/// The coding agents Browsa can add itself to in one click, and where each keeps its MCP settings.
enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code", codex = "Codex", cursor = "Cursor", vsCode = "VS Code"

    var id: String { rawValue }

    /// The name it connects as, for its app icon.
    var caller: String {
        switch self {
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .cursor: "cursor"
        case .vsCode: "vscode"
        }
    }

    /// Whether a connected agent's name ("claude-code", "codex-mcp-client", "Visual Studio Code") is this one.
    func matches(_ name: String) -> Bool {
        let n = name.lowercased()
        switch self {
        case .claudeCode: return n.contains("claude")
        case .codex: return n.contains("codex")
        case .cursor: return n.contains("cursor")
        case .vsCode: return n.contains("visual studio") || n.contains("vscode") || n.contains("copilot")
        }
    }

    /// The file Browsa writes, for the ones it sets up by file. Claude Code goes through its own `claude` command.
    var configFile: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return nil
        case .codex: return home.appending(path: ".codex/config.toml")
        case .cursor: return home.appending(path: ".cursor/mcp.json")
        case .vsCode: return home.appending(path: "Library/Application Support/Code/User/mcp.json")
        }
    }

    /// Shown under the Add button, before it's pressed.
    var addHint: String {
        switch self {
        case .claudeCode: "Adds Browsa for every project, using the claude command."
        case .codex: "Adds Browsa to ~/.codex/config.toml."
        case .cursor: "Adds Browsa to ~/.cursor/mcp.json."
        case .vsCode: "Adds Browsa to VS Code's mcp.json, for Copilot's agent mode."
        }
    }

    /// What to do once it's added, until the agent calls.
    var nextStep: String {
        switch self {
        case .claudeCode: "Start a new Claude Code session. It connects on its first call."
        case .codex: "Restart Codex. It connects on its first call."
        case .cursor: "Restart Cursor if it's open. It connects on its first call."
        case .vsCode: "Open Copilot Chat in Agent mode. Browsa is listed under MCP Servers."
        }
    }

    /// Where to paste the setup by hand.
    var manualHint: String {
        switch self {
        case .claudeCode: "Or paste this into Terminal:"
        case .codex: "Or add this to ~/.codex/config.toml:"
        case .cursor: "Or add this to ~/.cursor/mcp.json, inside \"mcpServers\":"
        case .vsCode: "Or add this to VS Code's mcp.json, inside \"servers\":"
        }
    }

    /// The exact setup text, token included.
    func setupText(name: String, url: String, token: String) -> String {
        switch self {
        case .claudeCode:
            // User scope: Browsa is there in every project, not just the folder it was added from.
            return "claude mcp add --scope user --transport http \(name) \(url) --header \"Authorization: Bearer \(token)\""
        case .codex:
            return """
                [mcp_servers.\(name)]
                url = "\(url)"
                http_headers = { Authorization = "Bearer \(token)" }
                """
        case .cursor:
            return """
                "\(name)": {
                  "url": "\(url)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
                """
        case .vsCode:
            return """
                "\(name)": {
                  "type": "http",
                  "url": "\(url)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
                """
        }
    }
}

/// One-click setup for each agent, and whether each already has Browsa (and with which token).
///
/// Claude Code is added with its own `claude mcp add` (at user scope). Codex, Cursor and VS Code
/// keep their MCP servers in a file, so Browsa adds its entry there and leaves the rest as it was.
/// Needs Browsa outside the App Sandbox, which the Mac app is (Developer ID).
@MainActor @Observable
final class AgentSetup {
    enum State: Equatable {
        case idle
        case working
        /// Added (or updated). The agent picks it up in its next session.
        case added
        case notInstalled
        case failed(String)
    }

    /// What's in the agent's settings now.
    enum Found: Equatable {
        case unknown
        case notAdded
        case added
        /// Added, but with a token Browsa no longer accepts (reset since, or copied from another Mac).
        case oldToken
    }

    private(set) var state: [AgentClient: State] = [:]
    private(set) var found: [AgentClient: Found] = [:]
    /// Whether each agent looks installed on this Mac.
    private(set) var installed: [AgentClient: Bool] = [:]

    func state(_ client: AgentClient) -> State { state[client] ?? .idle }
    func found(_ client: AgentClient) -> Found { found[client] ?? .unknown }

    /// Adds Browsa to an agent, or updates the entry it has (an old port or token, say).
    func add(_ client: AgentClient, name: String, url: String, token: String) async {
        state[client] = .working
        let result: State
        switch client {
        case .claudeCode: result = await Self.addToClaudeCode(name: name, url: url, token: token)
        case .codex: result = Self.write(client) { Self.codexConfig(replacing: $0, name: name, url: url, token: token) }
        case .cursor: result = Self.write(client) { try Self.jsonConfig(replacing: $0, key: "mcpServers", name: name,
                                                                         entry: ["url": url, "headers": ["Authorization": "Bearer \(token)"]]) }
        case .vsCode: result = Self.write(client) { try Self.jsonConfig(replacing: $0, key: "servers", name: name,
                                                                         entry: ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]) }
        }
        state[client] = result
        if result == .added { found[client] = .added; installed[client] = true }
    }

    /// Takes Browsa out of an agent again.
    @discardableResult
    func remove(_ client: AgentClient, name: String) async -> Bool {
        let ok: Bool
        switch client {
        case .claudeCode:
            guard let claude = await Self.findClaude() else { state[client] = .notInstalled; return false }
            ok = await Self.run(claude, ["mcp", "remove", "--scope", "user", name]).status == 0
        case .codex:
            ok = Self.write(client) { Self.codexConfig(replacing: $0, name: name, url: nil, token: nil) } == .added
        case .cursor:
            ok = Self.write(client) { try Self.jsonConfig(replacing: $0, key: "mcpServers", name: name, entry: nil) } == .added
        case .vsCode:
            ok = Self.write(client) { try Self.jsonConfig(replacing: $0, key: "servers", name: name, entry: nil) } == .added
        }
        if ok { state[client] = .idle; found[client] = .notAdded }
        return ok
    }

    func reset(_ client: AgentClient) { state[client] = .idle }

    /// Looks at each agent's settings: installed, added, and whether its token is the current one.
    func refresh(name: String, token: String) async {
        let claude = await Self.findClaude()
        for client in AgentClient.allCases {
            installed[client] = client == .claudeCode ? claude != nil : Self.looksInstalled(client)
            found[client] = await Self.lookUp(client, name: name, token: token)
        }
    }

    /// After Reset Token: every agent that has Browsa gets the new one.
    /// Returns the agents it updated.
    func updateAll(name: String, url: String, oldToken: String, token: String) async -> [AgentClient] {
        var updated: [AgentClient] = []
        for client in AgentClient.allCases {
            let had = await Self.lookUp(client, name: name, token: oldToken)
            guard had == .added || had == .oldToken else { continue }
            await add(client, name: name, url: url, token: token)
            if state(client) == .added { updated.append(client) }
        }
        return updated
    }

    // MARK: Claude Code

    private static func addToClaudeCode(name: String, url: String, token: String) async -> State {
        guard let claude = await findClaude() else { return .notInstalled }
        // Replacing: `mcp add` refuses a name that exists.
        _ = await run(claude, ["mcp", "remove", "--scope", "user", name])
        let result = await run(claude, ["mcp", "add", "--scope", "user", "--transport", "http", name, url,
                                        "--header", "Authorization: Bearer \(token)"])
        if result.status == 0 { return .added }
        let why = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(why.isEmpty ? "Claude Code couldn't add Browsa (exit \(result.status))." : String(why.prefix(240)))
    }

    /// Apps don't get your shell's PATH, so look where the installers put it, then ask your shell
    /// the way Terminal starts it (interactive and login, so ~/.zshrc and nvm count too).
    nonisolated static func findClaude() async -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                          "\(home)/.volta/bin/claude", "\(home)/.asdf/shims/claude", "\(home)/.local/share/mise/shims/claude",
                          "\(home)/Library/pnpm/claude", "\(home)/.yarn/bin/claude"]
        // nvm: one folder per Node version, newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/claude" }
        }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        for flags in ["-lc", "-ilc"] {
            let r = await run(shell, [flags, "command -v claude"], timeout: 8)
            let path = r.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if r.status == 0, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: Looking

    private nonisolated static func looksInstalled(_ client: AgentClient) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let apps: [String]
        let paths: [String]
        switch client {
        case .claudeCode: return false
        case .codex: apps = ["com.openai.codex"]; paths = ["\(home)/.codex"]
        case .cursor: apps = ["com.todesktop.230313mzl4w4u92"]; paths = ["\(home)/.cursor"]
        case .vsCode: apps = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]; paths = ["\(home)/Library/Application Support/Code/User"]
        }
        return apps.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            || paths.contains { fm.fileExists(atPath: $0) }
    }

    /// Whether the agent has Browsa, and with which token. Only reads.
    private nonisolated static func lookUp(_ client: AgentClient, name: String, token: String) async -> Found {
        let header = "Bearer \(token)"
        func compare(_ auth: String?) -> Found { auth == nil ? .notAdded : auth == header ? .added : .oldToken }
        switch client {
        case .claudeCode:
            // User-scope servers live at the top of ~/.claude.json.
            let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
            guard let root = readJSON(file) else { return .unknown }
            guard let entry = (root["mcpServers"] as? [String: Any])?[name] as? [String: Any] else { return .notAdded }
            return compare((entry["headers"] as? [String: Any])?["Authorization"] as? String ?? "")
        case .codex:
            guard let file = client.configFile else { return .unknown }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .notAdded }
            guard let block = codexBlock(in: text, name: name) else { return .notAdded }
            return block.contains(header) ? .added : .oldToken
        case .cursor, .vsCode:
            guard let file = client.configFile else { return .unknown }
            guard let root = readJSON(file, lenient: true) else { return .notAdded }
            let key = client == .cursor ? "mcpServers" : "servers"
            guard let entry = (root[key] as? [String: Any])?[name] as? [String: Any] else { return .notAdded }
            return compare((entry["headers"] as? [String: Any])?["Authorization"] as? String ?? "")
        }
    }

    private nonisolated static func readJSON(_ file: URL, lenient: Bool = false) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: lenient ? [.json5Allowed] : [])) as? [String: Any]
    }

    // MARK: Writing

    struct Unreadable: Error {}

    /// Reads the agent's file (or nothing, when there isn't one), changes it, and writes it back in one go.
    private static func write(_ client: AgentClient, _ change: (String) throws -> String) -> State {
        guard let file = client.configFile else { return .failed("Nothing to write for \(client.rawValue).") }
        let fm = FileManager.default
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        do {
            let new = try change(old)
            if new == old { return .added }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A copy of what was there, once, in case anyone wants it back.
            if !old.isEmpty {
                let backup = file.appendingPathExtension("before-browsa")
                if !fm.fileExists(atPath: backup.path) { try? old.write(to: backup, atomically: true, encoding: .utf8) }
            }
            try new.write(to: file, atomically: true, encoding: .utf8)
            return .added
        } catch is Unreadable {
            return .failed("\(file.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "~")) has comments or something else Browsa won't rewrite. Copy the setup below and paste it in yourself.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A JSON settings file with Browsa's entry set (or taken out, when `entry` is nil). Everything else stays.
    nonisolated static func jsonConfig(replacing text: String, key: String, name: String, entry: [String: Any]?) throws -> String {
        var root: [String: Any] = [:]
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Strict JSON only: rewriting a file with comments would lose them.
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw Unreadable() }
            root = parsed
        }
        var servers = root[key] as? [String: Any] ?? [:]
        if servers[name] == nil, entry == nil { return text }
        servers[name] = entry
        root[key] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Codex's config.toml with Browsa's table set (or taken out, when `url` is nil). Other lines stay as they were.
    nonisolated static func codexConfig(replacing text: String, name: String, url: String?, token: String?) -> String {
        let table = "mcp_servers.\(name)"
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                let header = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                skipping = header == table || header.hasPrefix(table + ".")
            }
            if !skipping { kept.append(line) }
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        var out = kept.joined(separator: "\n")
        if let url, let token {
            if !out.isEmpty { out += "\n\n" }
            out += AgentClient.codex.setupText(name: name, url: url, token: token)
        }
        return out.isEmpty ? out : out + "\n"
    }

    /// Browsa's table in a config.toml, if it has one.
    private nonisolated static func codexBlock(in text: String, name: String) -> String? {
        let table = "mcp_servers.\(name)"
        var lines: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                let header = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                inside = header == table || header.hasPrefix(table + ".")
            }
            if inside { lines.append(line) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Running

    struct Result: Sendable { let status: Int32; let output: String }

    nonisolated static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) async -> Result {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: Result(status: proc.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
            do { try p.run() } catch {
                cont.resume(returning: Result(status: -1, output: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}
