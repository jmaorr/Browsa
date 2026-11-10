import SwiftUI
import AppKit

// The "Let your agents in" card, wired to the real agent bridge: Add to Claude Code runs the same
// setup as the Agents panel, Codex and Cursor get their exact config with the token, and Watch a
// Demo runs Browsa's own scripted agent. The card ticks when an agent is added or connects, or
// once the demo has played.

/// The agents the card sets up, with where each one keeps its MCP settings.
enum WelcomeAgent: String, CaseIterable, Identifiable {
    case claude = "Claude Code", codex = "Codex", cursor = "Cursor"
    var id: String { rawValue }
    /// The name the agent connects as, for its app icon and for spotting it among connected agents.
    var caller: String { self == .claude ? "claude-code" : rawValue.lowercased() }
    var configHint: String {
        switch self {
        case .claude: ""
        case .codex: "Add this to ~/.codex/config.toml, then restart Codex"
        case .cursor: "Add this to ~/.cursor/mcp.json, then restart Cursor"
        }
    }
}

extension AgentBridge {
    /// The exact setup text for an agent, token included.
    func setupText(for agent: WelcomeAgent) -> String {
        switch agent {
        case .claude: claudeCodeCommand
        case .codex: """
            [mcp_servers.\(AgentBridge.mcpName)]
            url = "\(endpoint)"
            http_headers = { Authorization = "Bearer \(token)" }
            """
        case .cursor: """
            { "mcpServers": { "\(AgentBridge.mcpName)": {
                "url": "\(endpoint)",
                "headers": { "Authorization": "Bearer \(token)" } } } }
            """
        }
    }

    func isConnected(_ agent: WelcomeAgent) -> Bool {
        connectedAgents.contains { $0.lowercased().contains(agent.rawValue.lowercased().components(separatedBy: " ")[0]) }
    }
}

/// The left of the agents card: the Choose badge and a line.
struct AgentsLead: View {
    let done: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TryBadge(kind: .choose, done: done)
                .environment(\.colorScheme, .light)
            Text(done ? "Connected. Ask your agent to open a page in Browsa." : "Pick your agent and connect it, or watch Browsa's demo agent first.")
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The connector set into the right of the agents card.
struct AgentConnectPanel: View {
    let done: Bool
    let complete: () -> Void
    @Environment(Browser.self) private var browser
    @State private var agent = WelcomeAgent.claude
    @State private var copied = false
    @State private var revealed = false
    @State private var demoStarted = false

    private var agents: AgentBridge? { browser.library.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(WelcomeAgent.allCases) { a in
                    AgentButton(agent: a, selected: agent == a, connected: agents?.isConnected(a) == true) {
                        withAnimation(.smooth(duration: 0.25)) { agent = a; copied = false }
                    }
                }
            }
            if let agents {
                if agent == .claude { claude(agents) } else { config(agents) }
            } else {
                Text("Agents are turned off. Turn them on in Settings › Agents.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .padding(.vertical, 20)
        .padding(.trailing, 20)
        .onChange(of: agents?.claudeCodeSetup.state) { _, s in if s == .added { complete() } }
        .onChange(of: agents?.connectedAgents) { _, list in
            if list?.contains(where: { $0 != AgentDemo.agentName }) == true { complete() }
        }
        .onChange(of: agents?.demo.isRunning) { was, now in
            // The demo having played through counts: you've seen what an agent does here.
            if was == true, now == false, demoStarted { complete() }
        }
    }

    // MARK: Claude Code: one button, the same setup as the Agents panel

    @ViewBuilder private func claude(_ agents: AgentBridge) -> some View {
        let setup = agents.claudeCodeSetup
        VStack(alignment: .leading, spacing: 10) {
            Text("Adds Browsa to Claude Code for every project. Your token stays on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    Task { await setup.add(name: AgentBridge.mcpName, url: agents.endpoint, token: agents.token) }
                } label: {
                    Label(setup.state == .added ? "Added to Claude Code" : "Add to Claude Code",
                          systemImage: setup.state == .added ? "checkmark" : "plus")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(setup.state == .working || setup.state == .added)
                if setup.state == .working { ProgressView().controlSize(.small) }
            }
            Group {
                switch setup.state {
                case .added:
                    if agents.isConnected(.claude) {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Start a new Claude Code session. It connects on its first call.")
                    }
                case .notInstalled:
                    Text("Claude Code isn't installed on this Mac. Install it, or copy the command from the Agents panel.")
                        .foregroundStyle(.orange)
                case .failed(let why):
                    Text(why).foregroundStyle(.red).lineLimit(2)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Codex and Cursor: the exact config, token masked until revealed

    @ViewBuilder private func config(_ agents: AgentBridge) -> some View {
        let text = agents.setupText(for: agent)
        VStack(alignment: .leading, spacing: 8) {
            Text(agent.configHint).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(revealed ? text : text.replacingOccurrences(of: agents.token, with: String(repeating: "•", count: 12)))
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.black.opacity(0.25), in: .rect(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(.smooth(duration: 0.2)) { copied = true }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Button(revealed ? "Hide Token" : "Show Token") { withAnimation(.smooth(duration: 0.2)) { revealed.toggle() } }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                Spacer(minLength: 0)
                if agents.isConnected(agent) {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.green)
                } else if copied {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for \(agent.rawValue)…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("No agent handy?").foregroundStyle(.secondary)
            Button(agents?.demo.isRunning == true ? "Demo running…" : "Watch a Demo", systemImage: "play.fill") {
                guard let agents else { return }
                demoStarted = true
                agents.demo.start(bridge: agents, in: browser)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(agents == nil || agents?.demo.isRunning == true)
        }
        .font(.system(size: 12))
    }
}

/// An agent to set up: its app icon (when installed) and name in a glass capsule.
private struct AgentButton: View {
    let agent: WelcomeAgent
    let selected: Bool
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AgentIcon(caller: agent.caller, size: 15)
                Text(agent.rawValue).font(.system(size: 12, weight: .medium)).fixedSize()
                if connected {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        .animation(.smooth(duration: 0.2), value: selected)
    }
}
