import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility

/// The slim panel on the right: Margin notes, the agent log, or an extension's side panel.
/// It sits beside the page and narrows it, so nothing on the page is ever hidden behind it.
struct RightPanel: View {
    @Environment(Browser.self) private var browser
    let kind: PanelKind

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                switch kind {
                case .margin: MarginPanel()
                case .agents: AgentsPanel()
                case .extensionPanel(let id): ExtensionPanelView(extensionID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background.opacity(0.92))
        .clipShape(.rect(cornerRadius: PageCard.radius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 2) {
            tab(.margin, "Notes", "text.bubble")
            tab(.agents, "Agents", "sparkles")
            ForEach(browser.library.extensions.filter { $0.panelURL != nil }, id: \.id) { ext in
                tab(.extensionPanel(id: ext.id), ext.name, "puzzlepiece.extension")
            }
            Spacer(minLength: 0)
            Button { browser.panel = nil } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .help("Hide Panel (⌥⌘S)")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    private func tab(_ k: PanelKind, _ title: String, _ symbol: String) -> some View {
        Button { browser.panel = k } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .background(kind == k ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind == k ? .primary : .secondary)
        .help(title)
    }
}

// MARK: - Margin

/// Notes on this page. Yours and your agents', in one thread per note.
struct MarginPanel: View {
    @Environment(Browser.self) private var browser
    @State private var draft = ""
    @State private var quote: String?
    @State private var showResolved = false
    @FocusState private var composing: Bool

    private var url: URL? { browser.currentTab?.url }
    private var margin: MarginStore { browser.library.margin }
    private var notes: [MarginNote] {
        guard let url else { return [] }
        return margin.notes(on: url).filter { showResolved || $0.status == .open }
    }

    var body: some View {
        VStack(spacing: 0) {
            if url == nil {
                ContentUnavailableView("No page", systemImage: "text.bubble",
                                       description: Text("Notes belong to pages. Open one to leave a note on it."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if notes.isEmpty {
                            Text("Leave a note on this page: a change to make, a bug, a question. Agents connected to Browsa see it too, and reply here when they've acted on it.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                        ForEach(notes) { NoteCard(note: $0) }
                    }
                    .padding(12)
                }
                footer
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote {
                HStack(alignment: .top) {
                    Text("“\(quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { self.quote = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            TextField("Add a note…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composing)
                .onSubmit(add)
            HStack {
                Button("Quote Selection", systemImage: "text.quote", action: takeSelection)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Pin the note to the text selected on the page")
                Toggle("Resolved", isOn: $showResolved).toggleStyle(.button).buttonStyle(.borderless).controlSize(.small)
                Spacer()
                Menu {
                    Button("Copy as Markdown") { copyMarkdown() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .padding(10)
    }

    private func add() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let url, let tab = browser.currentTab else { return }
        margin.add(MarginNote(url: url, pageTitle: tab.title, anchor: .init(quote: quote), body: body))
        draft = ""
        quote = nil
    }

    private func takeSelection() {
        guard let page = browser.currentController?.page else { return }
        Task {
            let text = (try? await page.evaluate("return String(window.getSelection() || '').trim().slice(0, 500)", inWorld: "browsa.margin")) as? String
            quote = (text?.isEmpty ?? true) ? nil : text
            composing = true
        }
    }

    private func copyMarkdown() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(margin.markdown(for: url), forType: .string)
        browser.showToast("Copied notes as Markdown")
    }
}

private struct NoteCard: View {
    @Environment(Browser.self) private var browser
    let note: MarginNote
    @State private var reply = ""

    private var margin: MarginStore { browser.library.margin }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AuthorBadge(author: note.author)
                Text(note.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if note.status == .resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                }
            }
            if let q = note.anchor.quote {
                Text(q).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
            }
            Text(note.body).font(.callout).textSelection(.enabled)
            ForEach(note.replies) { r in
                VStack(alignment: .leading, spacing: 2) {
                    AuthorBadge(author: r.author)
                    Text(r.body).font(.callout).textSelection(.enabled)
                }
                .padding(.leading, 10)
            }
            HStack {
                TextField("Reply", text: $reply).textFieldStyle(.plain).font(.callout)
                    .onSubmit { margin.reply(to: note.id, author: .you, body: reply); reply = "" }
                if note.status == .open {
                    Button("Resolve") { margin.resolve(note.id, by: .you) }.controlSize(.small)
                } else {
                    Button("Reopen") { margin.reopen(note.id) }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(note.status == .open ? 0.6 : 0.3), in: .rect(cornerRadius: 10))
        .contextMenu {
            Button("Delete Note", role: .destructive) { margin.delete(note.id) }
        }
    }
}

private struct AuthorBadge: View {
    let author: MarginNote.Author
    var body: some View {
        switch author {
        case .you: Text("You").font(.caption.weight(.semibold))
        case .agent(let name):
            Label(name, systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.purple)
        }
    }
}

// MARK: - Agents

/// Who's connected, what they're doing, and Stop.
struct AgentsPanel: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    private var agents: AgentBridge { browser.library.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status.padding(12)
            Divider().opacity(0.5)
            if agents.activity.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "sparkles",
                                       description: Text("When an agent reads a page, clicks or resolves a note, it shows up here."))
            } else {
                List(agents.activity) { ActivityRow(entry: $0) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
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
                    Text(agents.isPaused ? "Paused" : agents.isRunning ? "Ready" : "Not running").font(.callout.weight(.semibold))
                    Text(agents.connectedAgents.isEmpty ? "No agent has acted yet" : agents.connectedAgents.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(agents.isPaused ? "Resume" : "Stop") { agents.isPaused.toggle() }
                    .tint(agents.isPaused ? nil : .red)
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: AgentActivity
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.caller) · \(entry.tool)").font(.caption.weight(.semibold))
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
        case .denied: Image(systemName: "hand.raised").foregroundStyle(.red)
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
