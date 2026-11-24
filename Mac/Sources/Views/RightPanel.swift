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
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PanelFill(), in: .rect(cornerRadius: PageCard.radius, style: .continuous))
        .clipShape(.rect(cornerRadius: PageCard.radius, style: .continuous))
    }

    /// The panel's width, for how many tool buttons fit in the header.
    @State private var width: CGFloat = 320

    /// The tool's name on the left, a rail of the other panel tools on the right. When the panel is
    /// too narrow for them all, the ones that don't fit go in a ••• menu (the open one always shows).
    private var header: some View {
        let (shown, more) = railTools
        return HStack(spacing: 6) {
            if let tool {
                Text(tool.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .layoutPriority(-1)
                if tool.stage == .preview { PreviewBadge() }
            }
            Spacer(minLength: 4)
            ForEach(shown) { t in railButton(t) }
            if !more.isEmpty {
                Menu {
                    ForEach(more) { t in
                        Button(t.title, systemImage: t.symbol) { browser.showPanel(t.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 24)
                        .overlay(alignment: .topTrailing) {
                            // Agents is in the menu with asks waiting: say so here.
                            if more.contains(where: { $0.id == "agents" }), !browser.library.agents.requests.isEmpty {
                                Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 1, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("More tools")
            }
            Divider().frame(height: 14)
            SidebarIconButton(symbol: "xmark", help: Shortcuts.shared.help("Close Panel", .panel)) { browser.togglePanel() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 38)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The tools that fit in the header at this width, and the rest. Room is kept for a short title.
    private var railTools: (shown: [Tool], more: [Tool]) {
        let tools = workbench.panelTools
        // Padding, a short title, the divider and the close button; each tool button is 26 + 6.
        let fixed: CGFloat = 18 + 76 + 4 + 13 + 34
        let slot: CGFloat = 32
        let fitsAll = Int((width - fixed) / slot)
        guard tools.count > fitsAll else { return (tools, []) }
        // One slot goes to the ••• menu.
        let count = max(1, fitsAll - 1)
        var shown = Array(tools.prefix(count))
        if !shown.contains(where: { $0.id == toolID }), let current = tools.first(where: { $0.id == toolID }) {
            shown[shown.count - 1] = current
        }
        let ids = Set(shown.map(\.id))
        return (shown, tools.filter { !ids.contains($0.id) })
    }

    private func railButton(_ t: Tool) -> some View {
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
    @State private var connecting = false
    @State private var confirmingReset = false
    @AppStorage("agentPromptDismissed") private var promptDismissed = false
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        if !agents.isEnabled {
            PanelEmptyState(title: "Let Agents Use Browsa", symbol: AgentIdentity.symbol,
                            message: "Claude Code, Codex, Cursor and other MCP agents can read pages, test your localhost in an Agent space you can watch, and work through your notes.") {
                VStack(spacing: 8) {
                    Button("Turn On Agents") { withAnimation(Motion.snappy) { agents.isEnabled = true; connecting = true } }
                    Button("Watch a Demo") { agents.demo.start(bridge: agents, in: browser) }
                        .buttonStyle(.link)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    status
                    if connecting || agents.connectedAgents.allSatisfy({ $0 == AgentDemo.agentName }) {
                        ConnectAgentCard { withAnimation(Motion.snappy) { connecting = false } }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if !promptDismissed {
                        TryItCard { withAnimation(Motion.snappy) { promptDismissed = true } }
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
            .confirmationDialog("Reset Browsa's agent token?", isPresented: $confirmingReset) {
                Button("Reset Token", role: .destructive) {
                    Task {
                        let updated = await agents.resetToken()
                        browser.showToast(updated.isEmpty ? "New token. Agents set up by hand need the new one."
                                          : "New token. Updated \(updated.map(\.rawValue).formatted(.list(type: .and))).")
                    }
                }
            } message: {
                Text("Agents using the old token stop working at once. Claude Code, Codex, Cursor and VS Code are updated for you if Browsa is set up in them; anything you set up by hand needs the new token pasted in.")
            }
        }
    }

    /// "Driving" only while calls are coming in; agents that went quiet a while ago grey out.
    private var status: some View {
        HStack(spacing: 10) {
            Circle().fill(agents.isPaused ? .orange : !agents.isRunning ? .red : agents.isActing ? AgentLive.color : .green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                if let problem = agents.problemDescription, !agents.isRunning {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(agents.isPaused ? "Stopped" : !agents.isRunning ? "Not running"
                     : agents.isActing ? "Driving" : agents.connectedAgents.isEmpty ? "Ready to connect" : "Connected · idle")
                    .font(.callout.weight(.semibold))
                    .contentTransition(.opacity)
                if !agents.connectedAgents.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(agents.connectedAgents, id: \.self) { name in
                            Label { Text(AgentIdentity.displayName(name)) } icon: { AgentIcon(caller: name, size: 12) }
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
                Button("Watch a Demo") { agents.demo.start(bridge: agents, in: browser) }
                Button("Show the Demo Prompt") { withAnimation(Motion.snappy) { promptDismissed = false } }
                Button("Clear Activity") { agents.clearActivity() }
                Divider()
                Menu("Remove From") {
                    ForEach(AgentClient.allCases) { client in
                        Button(client.rawValue) {
                            Task {
                                let ok = await agents.remove(client)
                                browser.showToast(ok ? "Removed Browsa from \(client.rawValue)" : "\(client.rawValue) didn't have Browsa")
                            }
                        }
                    }
                }
                Button("Reset Token…") { confirmingReset = true }
                Divider()
                Button("Agent Settings…") { browser.library.openSettings(pane: "agents") }
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

/// Set up where you'll use it: pick the agent, press Add, and the card waits until it connects.
/// The exact text to paste is underneath, for anyone who'd rather do it by hand.
private struct ConnectAgentCard: View {
    @Environment(Browser.self) private var browser
    let done: () -> Void
    @State private var client = AgentClient.claudeCode
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        let status = AgentSetupStatus(client, agents)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connect an Agent").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: done) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            GlassTabs(selection: $client, options: AgentClient.allCases, size: .small) { $0.rawValue }
                .frame(maxWidth: .infinity)
            if let at = agents.lastRejected { AgentRejectedNote(at: at) }
            HStack(spacing: 8) {
                AgentAddButton(client: client, agents: agents)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if status.tone == .waiting { ProgressView().controlSize(.mini) }
                if status.tone == .good { Image(systemName: "checkmark.circle.fill") }
                Text(status.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .font(.caption).foregroundStyle(status.color)
            DisclosureGroup("Set it up by hand") { AgentManualSetup(client: client, agents: agents).padding(.top, 6) }
                .disclosureGroupStyle(.row)
                .font(.caption).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Text("No agent handy?").foregroundStyle(.secondary)
                Button("Watch a Demo") { agents.demo.start(bridge: agents, in: browser) }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    .disabled(agents.demo.isRunning)
            }
            .font(.caption)
        }
        .animation(Motion.snappy, value: agents.isConnected(client))
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .task { await agents.refreshSetup() }
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
        case .yourTab: "\(AgentIdentity.displayName(request.caller)) wants to \(request.action.lowercased()) in your tab"
        case .yourTabs: "\(AgentIdentity.displayName(request.caller)) wants to see your open tabs"
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

/// Once a real agent is connected: a task to give it, on Supper, to see it work in Browsa.
private struct TryItCard: View {
    let dismiss: () -> Void
    @State private var copied = false
    /// browsa.app/demo/ once it's live; the bundled copy before that.
    @State private var prompt = AgentDemo.prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Try it", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide")
            }
            Text("Give your agent this, then watch it plan a dinner party in the Agent space.")
                .font(.caption).foregroundStyle(.secondary)
            Text(prompt)
                .font(.system(size: 12))
                .italic()
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentLive.color.opacity(0.12), in: .rect(cornerRadius: 8))
            Button(copied ? "Copied" : "Copy Prompt") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                withAnimation(Motion.snappy) { copied = true }
            }
            .buttonStyle(.glassProminent).controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .task { await AgentDemo.refresh(); prompt = AgentDemo.prompt }
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
    @Environment(Browser.self) private var browser
    let run: AgentRun
    private var texts: [UUID: String] { browser.library.agents.activityText }
    let startsOpen: Bool
    @State private var open: Bool?
    @State private var showCalls = false
    private var isOpen: Bool { open ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.snappy) { open = !isOpen } } label: {
                HStack(spacing: 7) {
                    AgentIcon(caller: run.caller, size: 14)
                    Text(AgentIdentity.displayName(run.caller)).font(.system(size: 12, weight: .semibold))
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
                                Text(texts[e.id] ?? AgentWords.sentence(tool: e.tool, fields: AgentWords.fields(e.summary)))
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

    private var panelURL: URL? {
        browser.library.extensionPanelPages[extensionID]
            ?? browser.library.extensions.first(where: { $0.id == extensionID })?.panelURL
    }

    var body: some View {
        Group {
            if let page {
                PageHost(view: page.view, focusesPage: false)
            } else {
                ProgressView()
            }
        }
        .task(id: panelURL) {
            page?.close()
            guard let url = panelURL else { page = nil; browser.library.shownExtensionPanels[extensionID] = nil; return }
            browser.library.shownExtensionPanels[extensionID] = url
            page = browser.engine.makePage(options: PageOptions(url: url), delegate: PanelPageDelegate.shared)
            page?.load(url)
        }
        .onDisappear { page?.close(); page = nil; browser.library.shownExtensionPanels[extensionID] = nil }
    }
}

/// Links an extension panel opens go to a new tab.
@MainActor
final class PanelPageDelegate: EnginePageDelegate {
    static let shared = PanelPageDelegate()

    /// window.open from a panel (Raindrop's Sign in): the page goes in a new tab. Blocking it, the
    /// default, left the button doing nothing.
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? {
        (NSApp.delegate as? AppDelegate)?.browser?.library.openPanelPopup(page: popup, url: url)
    }

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard request.isMainFrame, request.kind == .link, request.url.scheme == "https" || request.url.scheme == "http",
              let browser = (NSApp.delegate as? AppDelegate)?.browser else { return .allow }
        browser.newTab(url: request.url)
        return .cancel
    }
}
