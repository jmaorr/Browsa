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

/// Who's connected, what they're doing, and Stop.
struct AgentsPanel: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        if !agents.isEnabled {
            PanelEmptyState(title: "Let Agents Use Browsa", symbol: AgentIdentity.symbol,
                            message: "Claude Code, Codex, Cursor and other MCP agents can read pages, test your localhost in an Agent space you can watch, and work through your notes.") {
                Button("Set Up Agents…") { openSettings() }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                status.padding(12)
                if !agents.requests.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(agents.requests) { AgentRequestCard(request: $0) }
                    }
                    .padding([.horizontal, .bottom], 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Divider().opacity(0.5)
                if agents.activity.isEmpty {
                    PanelEmptyState(title: "No Activity Yet", symbol: AgentIdentity.symbol,
                                    message: "When an agent reads a page, clicks, or resolves a note, it shows up here.")
                } else {
                    List(agents.activity) { ActivityRow(entry: $0) }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if !agents.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("Let coding agents use Browsa").font(.headline)
                Text("Claude Code, Codex, Cursor and other MCP agents can read pages, test your localhost in an Agent space you can watch, and work through your notes.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Set Up…") { openSettings() }
            }
        } else {
            HStack {
                Circle().fill(agents.isPaused ? .orange : agents.isRunning ? .green : .red).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agents.isPaused ? "Stopped" : !agents.isRunning ? "Not running" : agents.isDriving ? "Working in the Agent space" : "Ready")
                        .font(.callout.weight(.semibold))
                    if agents.connectedAgents.isEmpty {
                        Text("No agent has acted yet").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(agents.connectedAgents, id: \.self) { name in
                                Label { Text(name) } icon: { AgentIcon(caller: name, size: 12) }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(agents.isPaused ? "Resume" : "Stop") {
                    withAnimation(Motion.snappy) { agents.isPaused ? agents.resume() : agents.stopAll() }
                }
                .buttonStyle(.borderedProminent)
                .tint(agents.isPaused ? .accentColor : .red)
            }
        }
    }
}

/// An agent waiting for you, inline: it never pops up or takes the keyboard, and the agent
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

private struct ActivityRow: View {
    let entry: AgentActivity
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    AgentIcon(caller: entry.caller, size: 12)
                    Text("\(entry.caller) · \(entry.tool)").font(.caption.weight(.semibold))
                }
                if !entry.summary.isEmpty { Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if case .failed(let why) = entry.outcome { Text(why).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            Spacer()
            Text(entry.at, style: .time).font(.caption2).foregroundStyle(.tertiary)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private var icon: some View {
        switch entry.outcome {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .denied: Image(systemName: "hand.raised").foregroundStyle(.secondary)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.red)
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
