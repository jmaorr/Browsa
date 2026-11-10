import Foundation
import Observation

/// One-click "Add to Claude Code": finds the `claude` command and runs `claude mcp add` for you,
/// at user scope so Browsa is there in every project. Needs Browsa outside the App Sandbox,
/// which the Mac app is (Developer ID).
@MainActor @Observable
final class ClaudeCodeSetup {
    enum State: Equatable {
        case idle
        case working
        /// Added (or updated). Claude Code picks it up in its next session.
        case added
        case notInstalled
        case failed(String)
    }

    private(set) var state = State.idle

    /// Runs `claude mcp add` with Browsa's URL and token. If a server with the same name is there
    /// already (an old port or token, say), it's replaced.
    func add(name: String, url: String, token: String) async {
        state = .working
        guard let claude = await Self.findClaude() else { state = .notInstalled; return }
        // Replacing: `mcp add` refuses a name that exists.
        _ = await Self.run(claude, ["mcp", "remove", "--scope", "user", name])
        let result = await Self.run(claude, ["mcp", "add", "--scope", "user", "--transport", "http", name, url,
                                             "--header", "Authorization: Bearer \(token)"])
        if result.status == 0 {
            state = .added
        } else {
            let why = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed(why.isEmpty ? "Claude Code couldn't add Browsa (exit \(result.status))." : String(why.prefix(240)))
        }
    }

    func reset() { state = .idle }

    /// Takes Browsa out of Claude Code again.
    func remove(name: String) async -> Bool {
        guard let claude = await Self.findClaude() else { state = .notInstalled; return false }
        let ok = await Self.run(claude, ["mcp", "remove", "--scope", "user", name]).status == 0
        if ok { state = .idle }
        return ok
    }

    /// Whether Claude Code has a server by this name at user scope.
    nonisolated static func isAdded(_ name: String) async -> Bool {
        guard let claude = await findClaude() else { return false }
        return await run(claude, ["mcp", "get", name]).status == 0
    }

    // MARK: Finding claude

    /// Apps don't get your shell's PATH, so look where the installers put it, then ask a login shell.
    nonisolated static func findClaude() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let r = await run(shell, ["-lc", "command -v claude"], timeout: 8)
        let path = r.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.status == 0 && path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
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
