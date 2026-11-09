import Foundation

/// A tool a coding agent can call through Browsa (MCP's "tools").
public struct AgentTool: Sendable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// PNG or JPEG, base64-encoded.
        case image(base64: String, mimeType: String)
    }

    public struct Result: Sendable, Equatable {
        public var content: [Content]
        public var isError: Bool

        public init(_ content: [Content], isError: Bool = false) {
            self.content = content
            self.isError = isError
        }

        public static func text(_ s: String) -> Result { Result([.text(s)]) }
        public static func error(_ s: String) -> Result { Result([.text(s)], isError: true) }
        /// Pretty JSON as text, which agents read well.
        public static func json(_ value: JSONValue) -> Result {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let text = (try? e.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return .text(text)
        }
    }

    public typealias Handler = @MainActor @Sendable (_ arguments: JSONValue, _ caller: AgentCaller) async throws -> Result

    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    /// Only reads. Shown to agents as a hint; every call, reads included, still goes through
    /// `AgentToolbox.authorize`.
    public let readOnly: Bool
    /// The plugin that offers it, or nil for Browsa's own.
    public let pluginID: String?
    public let handler: Handler

    public init(name: String, title: String, description: String, inputSchema: JSONValue = ["type": "object", "properties": [:]],
                readOnly: Bool, pluginID: String? = nil, handler: @escaping Handler) {
        precondition(AgentToolbox.isValidName(name), "tool names are letters, digits, _ and -")
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.pluginID = pluginID
        self.handler = handler
    }
}

/// Who's calling: the agent's name from its `initialize` request.
public struct AgentCaller: Sendable, Equatable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// One line in the agent activity log the right panel shows.
public struct AgentActivity: Identifiable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case running, done, failed(String), denied, stopped }
    public let id = UUID()
    public let caller: String
    public let tool: String
    public let summary: String
    public let at = Date()
    public var outcome: Outcome
}

/// Browsa's MCP server, without a transport: it takes a JSON-RPC message and gives back the reply.
/// The app puts it behind a localhost HTTP endpoint; tests call `handle` directly.
///
/// Speaks the parts of the Model Context Protocol agents use for tools: `initialize`, `ping`,
/// `tools/list` and `tools/call`.
@MainActor
public final class AgentToolbox {
    nonisolated public static let protocolVersion = "2025-06-18"

    nonisolated public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public let serverName: String
    public let serverVersion: String
    public private(set) var tools: [String: AgentTool] = [:]
    /// The answer to "may this call run?".
    public enum Verdict: Sendable, Equatable {
        case allow
        /// Refused, with what to tell the agent.
        case deny(String)
    }

    /// Asked before every call, reads included. Default: allow.
    public var authorize: @MainActor (AgentTool, JSONValue, AgentCaller) async -> Verdict = { _, _, _ in .allow }
    /// Every call, as it starts and as it ends.
    public var onActivity: @MainActor (AgentActivity) -> Void = { _ in }
    /// Told when the tool list changes, so the transport can send `notifications/tools/list_changed`.
    public var onToolsChanged: @MainActor () -> Void = {}
    /// Callers seen, by session, from their `initialize`.
    private var callers: [String: AgentCaller] = [:]
    /// Calls that are running now, so Stop can end them.
    private var running: [UUID: RunningCall] = [:]
    public var hasRunningCalls: Bool { !running.isEmpty }

    nonisolated public static let stoppedMessage = "The user pressed Stop in Browsa. Don't retry; wait until they tell you to carry on."

    public init(serverName: String = "Browsa", serverVersion: String) {
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    public func register(_ tool: AgentTool) {
        tools[tool.name] = tool
        onToolsChanged()
    }

    public func unregister(pluginID: String) {
        let before = tools.count
        tools = tools.filter { $0.value.pluginID != pluginID }
        if tools.count != before { onToolsChanged() }
    }

    // MARK: JSON-RPC

    /// One request or notification in; its response out, or nil for a notification.
    public func handle(_ data: Data, session: String = "default") async -> Data? {
        guard let message = try? JSONValue(data: data) else {
            return try? Self.error(id: nil, code: -32700, message: "Parse error").data()
        }
        // A batch.
        if let batch = message.array {
            var replies: [JSONValue] = []
            for m in batch { if let r = await respond(to: m, session: session) { replies.append(r) } }
            return replies.isEmpty ? nil : try? JSONValue.array(replies).data()
        }
        return try? await respond(to: message, session: session)?.data()
    }

    func respond(to message: JSONValue, session: String) async -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return id == nil ? nil : Self.error(id: id, code: -32600, message: "Invalid request")
        }
        // Notifications (no id) get no reply.
        guard let id, id != .null else { return nil }
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            let info = params["clientInfo"]
            callers[session] = AgentCaller(name: info?["name"]?.string ?? "An agent", version: info?["version"]?.string ?? "")
            let requested = params["protocolVersion"]?.string
            return Self.result(id: id, [
                "protocolVersion": .string(requested ?? Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": .string(serverName), "title": "Browsa", "version": .string(serverVersion)],
                "instructions": """
                Browsa is the user's own web browser. Pages open in an Agent space the user can see, signed in as \
                the user, so act as a careful guest: ask before anything that spends money, sends messages or \
                deletes. Margin notes (notes_list) are the user's feedback on pages; when you've acted on one, \
                reply and resolve it with notes_resolve.
                """,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let list: [JSONValue] = tools.values.sorted { $0.name < $1.name }.map { t in
                [
                    "name": .string(t.name),
                    "title": .string(t.title),
                    "description": .string(t.description),
                    "inputSchema": t.inputSchema,
                    "annotations": ["readOnlyHint": .bool(t.readOnly), "openWorldHint": true],
                ]
            }
            return Self.result(id: id, ["tools": .array(list)])
        case "tools/call":
            guard let name = params["name"]?.string, let tool = tools[name] else {
                return Self.error(id: id, code: -32602, message: "Unknown tool \(params["name"]?.string ?? "")")
            }
            let args = params["arguments"] ?? [:]
            let caller = callers[session] ?? AgentCaller(name: "An agent", version: "")
            let result = await call(tool, args: args, caller: caller)
            return Self.result(id: id, Self.encode(result))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func call(_ tool: AgentTool, args: JSONValue, caller: AgentCaller) async -> AgentTool.Result {
        var activity = AgentActivity(caller: caller.name, tool: tool.name, summary: Self.summary(args), outcome: .running)
        if case .deny(let why) = await authorize(tool, args, caller) {
            activity.outcome = why == Self.stoppedMessage ? .stopped : .denied
            onActivity(activity)
            return .error(why)
        }
        onActivity(activity)
        let outcome = await run(tool, args: args, caller: caller)
        switch outcome {
        case .finished(let result):
            activity.outcome = result.isError ? .failed(Self.firstText(result)) : .done
            onActivity(activity)
            return result
        case .threw(let message):
            activity.outcome = .failed(message)
            onActivity(activity)
            return .error(message)
        case .stopped:
            activity.outcome = .stopped
            onActivity(activity)
            return .error(Self.stoppedMessage)
        }
    }

    /// Ends every running call now: each answers its agent at once, and its work is cancelled.
    /// Work that can't be interrupted (a script already running in a page) finishes unseen.
    public func stopAll() {
        let calls = running
        running.removeAll()
        for call in calls.values { call.stop() }
    }

    enum Outcome { case finished(AgentTool.Result), threw(String), stopped }

    /// Runs the handler in its own task, and answers when it finishes or when Stop ends it,
    /// whichever comes first.
    private func run(_ tool: AgentTool, args: JSONValue, caller: AgentCaller) async -> Outcome {
        let id = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            let call = RunningCall(cont)
            running[id] = call
            call.task = Task { @MainActor [weak self] in
                let outcome: Outcome
                do {
                    let result = try await tool.handler(args, caller)
                    outcome = Task.isCancelled ? .stopped : .finished(result)
                } catch {
                    outcome = Task.isCancelled || error is CancellationError ? .stopped : .threw(error.localizedDescription)
                }
                self?.running[id] = nil
                call.finish(outcome)
            }
        }
    }

    @MainActor final class RunningCall {
        private var cont: CheckedContinuation<Outcome, Never>?
        var task: Task<Void, Never>?
        init(_ cont: CheckedContinuation<Outcome, Never>) { self.cont = cont }
        func finish(_ outcome: Outcome) {
            cont?.resume(returning: outcome)
            cont = nil
        }
        func stop() {
            task?.cancel()
            finish(.stopped)
        }
    }

    // MARK: Helpers

    static func encode(_ result: AgentTool.Result) -> JSONValue {
        let content: [JSONValue] = result.content.map {
            switch $0 {
            case .text(let s): ["type": "text", "text": .string(s)]
            case .image(let b64, let mime): ["type": "image", "data": .string(b64), "mimeType": .string(mime)]
            }
        }
        return ["content": .array(content), "isError": .bool(result.isError)]
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue?, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func summary(_ args: JSONValue) -> String {
        guard let o = args.object, !o.isEmpty else { return "" }
        return o.keys.sorted().compactMap { k in
            guard let v = o[k] else { return nil }
            let s = v.string ?? (try? v.data()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "\(k): \(s.prefix(60))"
        }.joined(separator: ", ")
    }

    static func firstText(_ r: AgentTool.Result) -> String {
        for c in r.content { if case .text(let s) = c { return String(s.prefix(200)) } }
        return ""
    }
}
