import AppKit
import SwiftUI

// The pieces of "connect an agent", shared by Settings › Agents, the Agents panel and Welcome:
// one Add button per agent that does the setup for you, a line saying where it's at, and the
// exact text to paste for anyone who'd rather do it by hand.

/// Where one agent's setup is at, in a line.
struct AgentSetupStatus {
    enum Tone { case plain, waiting, good, warning, bad }
    let text: String
    let tone: Tone

    @MainActor init(_ client: AgentClient, _ agents: AgentBridge) {
        let setup = agents.setup
        switch setup.state(client) {
        case .working:
            self.init(text: "Adding…", tone: .waiting)
        case .notInstalled:
            self.init(text: "Browsa couldn't find the claude command. Copy the command and paste it into Terminal.", tone: .warning)
        case .failed(let why):
            self.init(text: why, tone: .bad)
        case .added, .idle:
            if agents.isConnected(client) {
                self.init(text: "Connected", tone: .good)
            } else {
                switch setup.found(client) {
                case .oldToken: self.init(text: "Set up with an old token. Press Update to fix it.", tone: .warning)
                case .added: self.init(text: client.nextStep, tone: setup.state(client) == .added ? .waiting : .plain)
                case .notAdded, .unknown: self.init(text: client.addHint, tone: .plain)
                }
            }
        }
    }

    private init(text: String, tone: Tone) { self.text = text; self.tone = tone }

    var color: Color {
        switch tone {
        case .plain, .waiting: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// Add (or Update) for one agent: a capsule glass button that does the setup, then steps aside.
struct AgentAddButton: View {
    let client: AgentClient
    let agents: AgentBridge
    var size: ControlSize = .regular

    var body: some View {
        let setup = agents.setup
        let found = setup.found(client)
        let working = setup.state(client) == .working
        Group {
            if setup.state(client) == .notInstalled {
                CopyCapsule(title: "Copy Command", text: agents.setupText(for: client), prominent: true)
            } else if found == .added && setup.state(client) != .working {
                Label(agents.isConnected(client) ? "Connected" : "Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(agents.isConnected(client) ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
            } else {
                Button {
                    Task { await agents.add(client) }
                } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small) }
                        Text(found == .oldToken ? "Update" : "Add to \(client.rawValue)")
                    }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(working)
            }
        }
        .controlSize(size)
        .animation(Motion.snappy, value: setup.state(client))
        .animation(Motion.snappy, value: found)
    }
}

/// The exact setup for one agent, token hidden until asked, with Copy.
struct AgentManualSetup: View {
    let client: AgentClient
    let agents: AgentBridge
    @State private var revealed = false

    var body: some View {
        let text = agents.setupText(for: client)
        VStack(alignment: .leading, spacing: 8) {
            Text(client.manualHint).font(.caption).foregroundStyle(.secondary)
            Text(revealed ? text : text.replacingOccurrences(of: agents.token, with: String(repeating: "•", count: 12)))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 7))
            HStack(spacing: 8) {
                CopyCapsule(title: "Copy", text: text)
                Button(revealed ? "Hide Token" : "Show Token") { withAnimation(Motion.snappy) { revealed.toggle() } }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            .controlSize(.small)
        }
    }
}

/// A capsule glass Copy button that says Copied for a moment.
struct CopyCapsule: View {
    let title: String
    let text: String
    var prominent = false
    @State private var copied = false

    var body: some View {
        let button = Button(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Motion.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(2)); withAnimation(Motion.snappy) { copied = false } }
        }
        .buttonBorderShape(.capsule)
        if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }
}

/// Settings › Agents: one agent, its app icon, where it's at, and Add.
struct AgentSettingsRow: View {
    let client: AgentClient
    let agents: AgentBridge
    @State private var showManual = false

    var body: some View {
        let status = AgentSetupStatus(client, agents)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentIcon(caller: client.caller, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.rawValue)
                    HStack(spacing: 4) {
                        if status.tone == .good { Image(systemName: "checkmark.circle.fill") }
                        Text(status.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption).foregroundStyle(status.color)
                    .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                AgentAddButton(client: client, agents: agents)
                Menu {
                    Button(showManual ? "Hide Setup" : "Set Up by Hand…") { withAnimation(Motion.snappy) { showManual.toggle() } }
                    Button("Copy Setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(agents.setupText(for: client), forType: .string)
                    }
                    if agents.setup.found(client) == .added || agents.setup.found(client) == .oldToken {
                        Divider()
                        Button("Update") { Task { await agents.add(client) } }
                        Button("Remove from \(client.rawValue)") { Task { await agents.remove(client) } }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .fixedSize()
                .help("More")
            }
            if showManual {
                AgentManualSetup(client: client, agents: agents)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Something tried to connect with an old token", when it did.
struct AgentRejectedNote: View {
    let at: Date

    var body: some View {
        Label {
            Text("An agent tried to connect at \(at.formatted(date: .omitted, time: .shortened)) with an old or missing token. Press Update next to it below, or copy its setup again.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}
