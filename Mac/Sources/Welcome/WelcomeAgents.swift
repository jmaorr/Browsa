import SwiftUI
import AppKit

// The "Let your agents in" card, wired to the real agent bridge: Add runs the same setup as
// Settings › Agents and the Agents panel (Claude Code, Codex, Cursor or VS Code), the exact text
// to paste is a click away, and Watch a Demo runs Browsa's own scripted agent. The card ticks when
// an agent is added or connects, or once the demo has played.

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
    @State private var agent = AgentClient.claudeCode
    @State private var manual = false
    @State private var demoStarted = false
    @State private var promptCopied = false

    private var agents: AgentBridge? { browser.library.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(AgentClient.allCases) { a in
                    AgentButton(agent: a, selected: agent == a, connected: agents?.isConnected(a) == true) {
                        withAnimation(.smooth(duration: 0.25)) { agent = a; manual = false }
                    }
                }
            }
            if let agents {
                connect(agents)
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
        .onChange(of: agents?.setup.state) { _, s in if s?.values.contains(.added) == true { complete() } }
        .task { await agents?.refreshSetup() }
        .onChange(of: agents?.connectedAgents) { _, list in
            if list?.contains(where: { $0 != AgentDemo.agentName }) == true { complete() }
        }
        .onChange(of: agents?.demo.isRunning) { was, now in
            // The demo having played through counts: you've seen what an agent does here.
            if was == true, now == false, demoStarted { complete() }
        }
    }

    // MARK: One button per agent, the same setup as Settings and the Agents panel

    @ViewBuilder private func connect(_ agents: AgentBridge) -> some View {
        let status = AgentSetupStatus(agent, agents)
        let added = agents.setup.found(agent) == .added
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if added {
                    // Once added, the next step: a ready-made prompt to watch it drive Browsa.
                    tryPrompt
                } else {
                    AgentAddButton(client: agent, agents: agents, size: .large)
                }
                Button(manual ? "Hide Setup" : "Set Up by Hand") { withAnimation(.smooth(duration: 0.2)) { manual.toggle() } }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                Spacer(minLength: 0)
            }
            Group {
                if promptCopied {
                    Text("Copied. Paste it into a new \(agent.rawValue) chat and watch it drive Browsa in the Agent space.")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if status.tone == .good { Image(systemName: "checkmark.circle.fill") }
                        Text(status.text)
                    }
                    .foregroundStyle(status.color)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            if manual {
                AgentManualSetup(client: agent, agents: agents)
                    .transition(.opacity)
            }
        }
    }

    /// Copies Browsa's example task, for the person to paste into their agent's chat.
    private var tryPrompt: some View {
        Button(promptCopied ? "Prompt Copied" : "Try Example Prompt", systemImage: promptCopied ? "checkmark" : "text.bubble") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentDemo.prompt, forType: .string)
            withAnimation(.smooth(duration: 0.2)) { promptCopied = true }
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help(AgentDemo.prompt)
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
    let agent: AgentClient
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
