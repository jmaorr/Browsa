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
                    ContentUnavailableView("Not available", systemImage: "puzzlepiece.extension",
                                           description: Text("This tool was removed or turned off."))
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
            SidebarIconButton(symbol: "sidebar.right", help: "Hide Panel (⌥⌘S)") { browser.togglePanel() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
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

// MARK: - Margin

/// Notes on this page. Yours and your agents', in one thread per note. While the panel shows, each
/// open note is marked on the page: its quote highlighted, a numbered pin beside it.
struct MarginPanel: View {
    @Environment(Browser.self) private var browser
    @State private var draft = ""
    @State private var quote: String?
    @State private var showResolved = false
    @State private var selected: UUID?
    @FocusState private var composing: Bool

    private var url: URL? { browser.currentTab?.url }
    private var margin: MarginStore { browser.library.margin }
    private var notes: [MarginNote] {
        guard let url else { return [] }
        return margin.notes(on: url).filter { showResolved || $0.status == .open }
    }
    /// Open notes in panel order, numbered from 1 like their pins.
    private var openNotes: [MarginNote] { notes.filter { $0.status == .open } }

    /// Changes whenever the marks on the page need redrawing.
    private var markKey: String {
        let loading = browser.currentTab?.isLoading == true
        return "\(url?.absoluteString ?? "")|\(loading)|\(openNotes.map { "\($0.id)" }.joined(separator: ","))|\(selected?.uuidString ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if url == nil {
                ContentUnavailableView("No page", systemImage: "text.bubble",
                                       description: Text("Notes belong to pages. Open one to leave a note on it."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if notes.isEmpty {
                            Text("Leave a note on this page: a change to make, a bug, a question. Agents connected to Browsa see it too, and reply here when they've acted on it.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                        ForEach(notes) { note in
                            NoteCard(note: note, number: openNotes.firstIndex { $0.id == note.id }.map { $0 + 1 },
                                     isSelected: selected == note.id) {
                                withAnimation(Motion.snappy) { selected = selected == note.id ? nil : note.id }
                                if selected == note.id { reveal(note) }
                            }
                        }
                    }
                    .padding(10)
                }
                footer
            }
        }
        .task(id: markKey) { await drawMarks() }
        .onDisappear { Task { await clearMarks() } }
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

    // MARK: Marks on the page

    private func drawMarks() async {
        guard let page = browser.currentController?.page, browser.currentTab?.isLoading != true else { return }
        let marks: [[String: Any]] = openNotes.enumerated().map { i, n in
            var m: [String: Any] = ["n": i + 1, "selected": n.id == selected]
            if let q = n.anchor.quote { m["quote"] = q }
            if let s = n.anchor.selector { m["selector"] = s }
            return m
        }
        guard let data = try? JSONSerialization.data(withJSONObject: marks), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await page.evaluate(MarginMarks.script + "\nreturn window.__browsaMarks(\(json));", inWorld: "browsa.margin")
    }

    private func clearMarks() async {
        guard let page = browser.currentController?.page else { return }
        _ = try? await page.evaluate(MarginMarks.script + "\nreturn window.__browsaMarks([]);", inWorld: "browsa.margin")
    }

    /// Scrolls the page to the note's mark.
    private func reveal(_ note: MarginNote) {
        guard let n = openNotes.firstIndex(where: { $0.id == note.id }), let page = browser.currentController?.page else { return }
        Task { _ = try? await page.evaluate("const p = document.querySelector('.__browsa-pin[data-n=\"\(n + 1)\"]'); p && p.scrollIntoView({block: 'center', behavior: 'smooth'}); return !!p", inWorld: "browsa.margin") }
    }
}

/// Draws notes onto the page: quotes highlighted with the CSS Highlight API, elements outlined,
/// and a numbered pin at each. Pins don't take clicks, so the page works as normal under them.
enum MarginMarks {
    static let script = #"""
    if (!window.__browsaMarks) {
      window.__browsaMarks = (marks) => {
        window.__browsaLast = marks;
        document.querySelectorAll('.__browsa-pin, .__browsa-box').forEach(e => e.remove());
        if (window.CSS && CSS.highlights) { CSS.highlights.delete('browsa-note'); CSS.highlights.delete('browsa-note-selected'); }
        if (!document.getElementById('__browsa-mark-style')) {
          const st = document.createElement('style');
          st.id = '__browsa-mark-style';
          st.textContent = `
            ::highlight(browsa-note) { background-color: rgba(250, 204, 21, .32); }
            ::highlight(browsa-note-selected) { background-color: rgba(250, 204, 21, .62); }
            .__browsa-pin { position: absolute; z-index: 2147483646; pointer-events: none; width: 20px; height: 20px;
              border-radius: 10px 10px 10px 2px; background: #f5b60b; color: #1d1600; font: 600 11px/20px -apple-system, system-ui;
              text-align: center; box-shadow: 0 1px 3px rgba(0,0,0,.25); transform: translate(-4px, -22px); transition: transform .15s; }
            .__browsa-pin.sel { transform: translate(-4px, -22px) scale(1.18); box-shadow: 0 0 0 3px rgba(245,182,11,.35), 0 1px 3px rgba(0,0,0,.25); }
            .__browsa-box { position: absolute; z-index: 2147483645; pointer-events: none; border: 1.5px dashed rgba(245,182,11,.9);
              border-radius: 6px; }
            .__browsa-box.sel { border-style: solid; background: rgba(250, 204, 21, .10); }`;
          document.documentElement.appendChild(st);
        }
        const plain = [], chosen = [];
        const findText = (q) => {
          const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          for (let t = w.nextNode(); t; t = w.nextNode()) {
            const i = t.data.indexOf(q);
            if (i >= 0 && t.parentElement && !t.parentElement.closest('script,style')) {
              const r = document.createRange(); r.setStart(t, i); r.setEnd(t, i + q.length); return r;
            }
          }
          return null;
        };
        for (const m of marks) {
          let rect = null;
          if (m.quote) {
            const r = findText(m.quote.trim());
            if (r) { (m.selected ? chosen : plain).push(r); rect = r.getBoundingClientRect(); }
          }
          if (!rect && m.selector) {
            let el = null; try { el = document.querySelector(m.selector); } catch (e) {}
            if (el) {
              rect = el.getBoundingClientRect();
              const b = document.createElement('div');
              b.className = '__browsa-box' + (m.selected ? ' sel' : '');
              Object.assign(b.style, { left: (rect.left + scrollX - 4) + 'px', top: (rect.top + scrollY - 4) + 'px',
                width: (rect.width + 8) + 'px', height: (rect.height + 8) + 'px' });
              document.body.appendChild(b);
            }
          }
          if (!rect) continue;
          const p = document.createElement('div');
          p.className = '__browsa-pin' + (m.selected ? ' sel' : '');
          p.dataset.n = m.n; p.textContent = m.n;
          Object.assign(p.style, { left: (rect.left + scrollX) + 'px', top: (rect.top + scrollY) + 'px' });
          document.body.appendChild(p);
        }
        if (window.CSS && CSS.highlights && window.Highlight) {
          if (plain.length) CSS.highlights.set('browsa-note', new Highlight(...plain));
          if (chosen.length) CSS.highlights.set('browsa-note-selected', new Highlight(...chosen));
        }
        if (!window.__browsaResize) {
          window.__browsaResize = true;
          addEventListener('resize', () => window.__browsaMarks(window.__browsaLast || []));
        }
        return marks.length;
      };
    }
    """#
}

/// One note. Compact until you hover or pick it: then reply and resolve appear, and its mark on
/// the page scrolls into view.
private struct NoteCard: View {
    @Environment(Browser.self) private var browser
    let note: MarginNote
    /// Its pin's number on the page, for open notes.
    let number: Int?
    let isSelected: Bool
    let select: () -> Void
    @State private var reply = ""
    @State private var hovering = false

    private var margin: MarginStore { browser.library.margin }
    private var showsActions: Bool { hovering || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let number {
                    Text(verbatim: "\(number)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color(red: 0.11, green: 0.09, blue: 0))
                        .frame(width: 16, height: 16)
                        .background(Color(red: 0.96, green: 0.71, blue: 0.04), in: UnevenRoundedRectangle(
                            topLeadingRadius: 8, bottomLeadingRadius: 2, bottomTrailingRadius: 8, topTrailingRadius: 8))
                        .help("Pin \(number) on the page")
                }
                AuthorBadge(author: note.author)
                Text(Self.short(note.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    .help(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                if note.status == .resolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                } else if showsActions {
                    Button { margin.resolve(note.id, by: .you) } label: { Image(systemName: "checkmark.circle") }
                        .buttonStyle(.borderless).help("Resolve")
                        .transition(.opacity)
                }
            }
            // A button rather than a tap gesture, so a click picks the note even in a background window.
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    if let q = note.anchor.quote {
                        Text(q).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(Color(red: 0.96, green: 0.71, blue: 0.04).opacity(0.8)).frame(width: 2) }
                    }
                    Text(note.body).font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            ForEach(note.replies) { r in
                VStack(alignment: .leading, spacing: 2) {
                    AuthorBadge(author: r.author)
                    Text(r.body).font(.callout).textSelection(.enabled)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
            }
            if showsActions {
                HStack {
                    TextField("Reply", text: $reply).textFieldStyle(.plain).font(.callout)
                        .onSubmit { margin.reply(to: note.id, author: .you, body: reply); reply = "" }
                    if note.status == .resolved {
                        Button("Reopen") { margin.reopen(note.id) }.controlSize(.small)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(note.status == .open ? (isSelected ? 0.9 : 0.6) : 0.3), in: .rect(cornerRadius: 10))
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 0.96, green: 0.71, blue: 0.04).opacity(0.7), lineWidth: 1.5) }
        }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .contextMenu {
            Button("Delete Note", role: .destructive) { margin.delete(note.id) }
        }
    }

    /// "now", "4m", "3h", "2d": the panel is narrow.
    static func short(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
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
