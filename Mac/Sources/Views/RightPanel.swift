import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility

/// The slim panel on the right. It shows one tool from the workbench at a time and sits beside the
/// page, narrowing it, so nothing on the page is ever hidden behind it.
///
/// The panel only knows tools by their `Tool` entry: a plugin's panel arrives here the same way Notes does.
struct RightPanel: View {
    @Environment(Browser.self) private var browser
    let toolID: String

    private var workbench: Workbench { browser.library.workbench }
    private var tool: Tool? { workbench.tool(toolID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if let view = tool?.panel { view() } else {
                    PanelEmptyState(title: "Not Available", symbol: "puzzlepiece.extension",
                                    message: "This tool was removed or turned off.")
                }
            }
            .id(toolID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PanelFill(), in: .rect(cornerRadius: PageCard.radius, style: .continuous))
        .clipShape(.rect(cornerRadius: PageCard.radius, style: .continuous))
    }

    /// The tool's name on the left, a rail of the other panel tools on the right.
    private var header: some View {
        HStack(spacing: 6) {
            if let tool {
                Text(tool.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if tool.stage == .preview { PreviewBadge() }
            }
            Spacer(minLength: 4)
            ForEach(workbench.panelTools) { t in
                Button { browser.showPanel(t.id) } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 24)
                        .overlay(alignment: .topTrailing) {
                            // Asks waiting for you, on the Agents button.
                            if t.id == "agents", !browser.library.agents.requests.isEmpty {
                                Text(verbatim: "\(browser.library.agents.requests.count)")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .frame(minWidth: 13, minHeight: 13)
                                    .background(.orange, in: .capsule)
                                    .offset(x: 2, y: -1)
                            }
                        }
                        .background(t.id == toolID ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.id == toolID ? .primary : .secondary)
                .help(t.title)
            }
            Divider().frame(height: 14)
            SidebarIconButton(symbol: "xmark", help: "Close Panel (⌥⌘S)") { browser.togglePanel() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
    }
}

/// What a panel shows when it has nothing yet: centred in the space it has, with an icon, a line
/// on what will appear here, and at most one thing to do about it.
struct PanelEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.primary.opacity(0.06), in: .circle)
            VStack(spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: 260)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PanelEmptyState where Actions == EmptyView {
    init(title: String, symbol: String, message: String) {
        self.init(title: title, symbol: symbol, message: message) { EmptyView() }
    }
}

/// Marks UI that's shown with sample data while it's being designed.
struct PreviewBadge: View {
    var body: some View {
        Text("Preview")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .help("Sample data, for designing. Not wired up yet.")
    }
}

// Notes (the Margin panel) lives in NotesPanel.swift.

// MARK: - Agents

/// Who's connected, what they're doing, asks waiting for you, and Stop.
struct AgentsPanel: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    @State private var connecting = false
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        if !agents.isEnabled {
            PanelEmptyState(title: "Let Agents Use Browsa", symbol: AgentIdentity.symbol,
                            message: "Claude Code, Codex, Cursor and other MCP agents can read pages, test your localhost in an Agent space you can watch, and work through your notes.") {
                Button("Turn On Agents") { withAnimation(Motion.snappy) { agents.isEnabled = true; connecting = true } }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    status
                    if connecting || agents.connectedAgents.isEmpty {
                        ConnectAgentCard { withAnimation(Motion.snappy) { connecting = false } }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !agents.requests.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(agents.requests) { AgentRequestCard(request: $0) }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !agents.activity.isEmpty {
                        Text("Activity").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(Array(AgentRun.runs(agents.activity).enumerated()), id: \.element.id) { i, run in
                            AgentRunView(run: run, startsOpen: i == 0)
                        }
                    }
                }
                .padding(12)
                .animation(Motion.snappy, value: agents.requests.map(\.id))
            }
        }
    }

    /// "Driving" only while calls are coming in; agents that went quiet a while ago grey out.
    private var status: some View {
        HStack(spacing: 10) {
            Circle().fill(agents.isPaused ? .orange : !agents.isRunning ? .red : agents.isActing ? .purple : .green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(agents.isPaused ? "Stopped" : !agents.isRunning ? "Not running"
                     : agents.isActing ? "Driving" : agents.connectedAgents.isEmpty ? "Ready to connect" : "Connected · idle")
                    .font(.callout.weight(.semibold))
                    .contentTransition(.opacity)
                if !agents.connectedAgents.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(agents.connectedAgents, id: \.self) { name in
                            Label { Text(name) } icon: { AgentIcon(caller: name, size: 12) }
                                .opacity(agents.isIdle(name) ? 0.45 : 1)
                                .help(agents.isIdle(name) ? "\(name) hasn't called in a while" : name)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Connect an Agent…") { withAnimation(Motion.snappy) { connecting = true } }
                Button("Clear Activity") { agents.clearActivity() }
                Divider()
                Button("Agent Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize()
            Button(agents.isPaused ? "Resume" : "Stop") {
                withAnimation(Motion.snappy) { agents.isPaused ? agents.resume() : agents.stopAll() }
            }
            .buttonStyle(.glassProminent)
            .tint(agents.isPaused ? .accentColor : .red)
            .controlSize(.small)
        }
    }
}

/// Set up where you'll use it: pick the agent, copy its line, and the card waits until it connects.
private struct ConnectAgentCard: View {
    enum Kind: String, CaseIterable { case claude = "Claude Code", codex = "Codex", cursor = "Cursor" }

    @Environment(Browser.self) private var browser
    let done: () -> Void
    @State private var kind = Kind.claude
    @State private var revealed = false
    @State private var copied = false
    @Namespace private var ns
    private var agents: AgentBridge { browser.library.agents }

    private var connected: Bool {
        agents.connectedAgents.contains { $0.lowercased().contains(kind.rawValue.lowercased().components(separatedBy: " ")[0]) }
    }
    private var url: String { "http://127.0.0.1:\(AgentBridge.port)/mcp" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connect an Agent").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: done) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            // The same glass switch as Notes' This Page / This Site.
            HStack(spacing: 0) {
                ForEach(Kind.allCases, id: \.self) { k in
                    Button { withAnimation(Motion.snappy) { kind = k } } label: {
                        Text(k.rawValue)
                            .font(.system(size: 11, weight: kind == k ? .semibold : .medium))
                            .foregroundStyle(kind == k ? .primary : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 22)
                            .background {
                                if kind == k {
                                    Capsule().fill(.background).shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                        .matchedGeometryEffect(id: "kind", in: ns)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .glassEffect(.regular, in: .capsule)
            Text(kind == .claude ? "Run this once in a terminal:" : "Add an MCP server with this URL and header:")
                .font(.caption).foregroundStyle(.secondary)
            Text(revealed ? fullText : maskedText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(revealed ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                    withAnimation(Motion.snappy) { copied = true }
                }
                .buttonStyle(.glassProminent).controlSize(.small)
                Button(revealed ? "Hide Token" : "Show Token") { withAnimation(Motion.snappy) { revealed.toggle() } }
                    .controlSize(.small)
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for \(kind.rawValue)…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .animation(Motion.snappy, value: connected)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .onChange(of: kind) { copied = false }
    }

    private var header: String { "Authorization: Bearer \(agents.token)" }
    private var fullText: String {
        kind == .claude ? agents.claudeCodeCommand
                        : "URL: \(url)\n\(header)"
    }
    private var maskedText: String {
        fullText.replacingOccurrences(of: agents.token, with: String(repeating: "•", count: 12))
    }
}

/// just waits until you answer (or press Stop).
private struct AgentRequestCard: View {
    @Environment(Browser.self) private var browser
    let request: AgentRequest
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AgentIcon(caller: request.caller, size: 16)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "hand.raised.circle.fill").font(.system(size: 9)).foregroundStyle(.white, .orange).offset(x: 3, y: 3)
                    }
                Text(headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if case .yourTab(let id, let host) = request.grant {
                Button { showTab(id) } label: {
                    HStack(spacing: 6) {
                        Text("“\(request.tabTitle ?? "Untitled")”").lineLimit(1)
                        if !host.isEmpty { Text(host).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Show this tab")
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Allow") { withAnimation(Motion.snappy) { agents.answer(request.id, allow: false) } }
                Button("Allow") { withAnimation(Motion.snappy) { agents.answer(request.id, allow: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25)))
    }

    private var headline: String {
        switch request.grant {
        case .yourTab: "\(request.caller) wants to \(request.action.lowercased()) in your tab"
        case .yourTabs: "\(request.caller) wants to see your open tabs"
        }
    }

    private var detail: String {
        switch request.grant {
        case .yourTab: "It sees what you see there, signed in as you. Allowed for this tab until you quit."
        case .yourTabs: "Titles and addresses of tabs that aren't private. It still asks before using one."
        }
    }

    private func showTab(_ id: UUID) {
        guard let tab = browser.library.tab(id: id) else { return }
        if let space = browser.space(containing: tab) { browser.selectSpace(space) }
        browser.select(tab)
    }
}

/// An agent's calls, grouped into runs: one agent, close together in time.
struct AgentRun: Identifiable {
    let id: UUID
    let caller: String
    let entries: [AgentActivity]
    var at: Date { entries.first?.at ?? .now }

    /// Newest first, like `activity`. A run breaks when the agent changes or after a 2-minute gap.
    static func runs(_ activity: [AgentActivity]) -> [AgentRun] {
        var runs: [AgentRun] = []
        var current: [AgentActivity] = []
        for e in activity {
            if let last = current.last, last.caller != e.caller || last.at.timeIntervalSince(e.at) > 120 {
                runs.append(AgentRun(id: current[0].id, caller: current[0].caller, entries: current))
                current = []
            }
            current.append(e)
        }
        if !current.isEmpty { runs.append(AgentRun(id: current[0].id, caller: current[0].caller, entries: current)) }
        return runs
    }
}

private struct AgentRunView: View {
    let run: AgentRun
    let startsOpen: Bool
    @State private var open: Bool?
    @State private var showCalls = false
    private var isOpen: Bool { open ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.snappy) { open = !isOpen } } label: {
                HStack(spacing: 7) {
                    AgentIcon(caller: run.caller, size: 14)
                    Text(run.caller).font(.system(size: 12, weight: .semibold))
                    Text(run.at, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if !isOpen {
                        Text(run.entries.count == 1 ? "1 step" : "\(run.entries.count) steps").font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    // Oldest first inside a run, so it reads as a story.
                    ForEach(run.entries.reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            outcome(e).frame(width: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AgentWords.sentence(tool: e.tool, fields: AgentWords.fields(e.summary)))
                                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                if case .failed(let why) = e.outcome { Text(why).font(.caption).foregroundStyle(.red).lineLimit(2) }
                                if showCalls {
                                    Text("\(e.tool)  \(e.summary)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                        }
                    }
                    Button(showCalls ? "Hide Calls" : "Show Calls") { withAnimation(Motion.snappy) { showCalls.toggle() } }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }

    @ViewBuilder private func outcome(_ e: AgentActivity) -> some View {
        switch e.outcome {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
        case .denied: Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.secondary)
        case .stopped: Image(systemName: "stop.circle.fill").font(.system(size: 9)).foregroundStyle(.red)
        }
    }
}

// MARK: - Extension side panels

/// An extension's `side_panel` (Chrome) or `sidebar_action` (Firefox) page.
struct ExtensionPanelView: View {
    @Environment(Browser.self) private var browser
    let extensionID: String
    @State private var page: (any EnginePage)?

    var body: some View {
        Group {
            if let page {
                PageHost(view: page.view, focusesPage: false)
            } else {
                ProgressView()
            }
        }
        .task(id: extensionID) {
            page?.close()
            guard let url = browser.library.extensions.first(where: { $0.id == extensionID })?.panelURL else { page = nil; return }
            page = browser.engine.makePage(options: PageOptions(url: url), delegate: PanelPageDelegate.shared)
            page?.load(url)
        }
        .onDisappear { page?.close(); page = nil }
    }
}

/// Links an extension panel opens go to a new tab.
@MainActor
final class PanelPageDelegate: EnginePageDelegate {
    static let shared = PanelPageDelegate()

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard request.isMainFrame, request.kind == .link, request.url.scheme == "https" || request.url.scheme == "http",
              let browser = (NSApp.delegate as? AppDelegate)?.browser else { return .allow }
        browser.newTab(url: request.url)
        return .cancel
    }
}
