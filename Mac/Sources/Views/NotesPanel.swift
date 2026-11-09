import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility
import WebKitEngine

/// Yellow, like a sticky note: it reads as "a note" on any site and stays clear of agents' purple.
enum NoteColor {
    static let pin = Color(red: 0.96, green: 0.71, blue: 0.04)
    static let ink = Color(red: 0.11, green: 0.09, blue: 0)
}

/// A note being written, before it's added: what it points at on the page.
struct NoteDraft: Equatable {
    var url: URL
    var quote: String?
    var selector: String?
    /// How the element reads in the composer ("Pay $329 button").
    var label: String?
    var x: Double?
    var y: Double?

    var anchor: MarginNote.Anchor { .init(quote: quote, selector: selector, x: x, y: y) }
}

/// Notes state that outlives a panel view: drafts and the comment tool, per window.
@MainActor @Observable
final class NotesUI {
    static let shared = NotesUI()

    var drafts: [UUID: NoteDraft] = [:]
    /// Windows with the comment tool on.
    var picking: Set<UUID> = []
    /// Bumped to put the cursor in a window's composer.
    var focusRequests: [UUID: Int] = [:]
    /// Notes resolved a moment ago, which stay in view with Undo.
    var justResolved: [UUID: Date] = [:]

    func requestFocus(_ window: UUID) { focusRequests[window, default: 0] += 1 }

    /// "Add Note" on a page's right-click menu, for the element or selection under the pointer.
    static func installPageMenu(library: Library) {
        PageMenuItems.provider = { [weak library] view, point in
            guard let library,
                  let browser = library.windows.first(where: { $0.currentController?.page.view === view }),
                  let url = browser.currentTab?.url, url.scheme?.hasPrefix("http") == true else { return [] }
            let item = ClosureMenuItem(title: "Add Note") {
                Task { @MainActor in
                    guard let page = browser.currentController?.page else { return }
                    let raw = try? await page.evaluate(NotePicker.script + "\nreturn window.__browsaDescribe(\(point.x), \(point.y));",
                                                       inWorld: "browsa.margin")
                    shared.startDraft(from: raw as? [String: Any], url: url, in: browser)
                }
            }
            item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            return [item]
        }
    }

    /// Opens Notes with a draft pointing at what was picked on the page.
    func startDraft(from picked: [String: Any]?, url: URL, in browser: Browser) {
        var draft = NoteDraft(url: url)
        if let q = picked?["quote"] as? String, !q.isEmpty { draft.quote = q } else {
            draft.selector = picked?["selector"] as? String
            draft.label = picked?["label"] as? String
            draft.x = picked?["x"] as? Double
            draft.y = picked?["y"] as? Double
        }
        withAnimation(Motion.snappy) { drafts[browser.id] = draft }
        picking.remove(browser.id)
        if browser.panel != "notes" { browser.showPanel("notes") }
        requestFocus(browser.id)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// MARK: - Panel

/// Notes on this page or across the site. Yours and your agents', a thread per note. While the
/// panel is open, open notes are marked on the page.
struct MarginPanel: View {
    enum Scope: String, CaseIterable { case page = "This Page", site = "This Site" }

    @Environment(Browser.self) private var browser
    @State private var scope = Scope.page
    @State private var showResolved = false
    @State private var selected: UUID?

    private var ui: NotesUI { .shared }
    private var url: URL? { browser.currentTab?.url }
    private var margin: MarginStore { browser.library.margin }

    private func visible(_ list: [MarginNote]) -> [MarginNote] {
        list.filter { showResolved || $0.status == .open || ui.justResolved[$0.id] != nil }
    }
    private var pageNotes: [MarginNote] { url.map { visible(margin.notes(on: $0)) } ?? [] }
    private var siteNotes: [MarginNote] { url.map { visible(margin.notes(onSiteOf: $0)) } ?? [] }
    private struct ResolvedSet: Equatable { let site: String?; let ids: Set<UUID> }
    private var siteResolvedIDs: [UUID] { url.map { margin.notes(onSiteOf: $0).filter { $0.status == .resolved }.map(\.id) } ?? [] }
    /// Open notes on this page, in order: pin 1, 2, 3.
    private var pinned: [MarginNote] { url.map { margin.notes(on: $0).filter { $0.status == .open } } ?? [] }

    private var markKey: String {
        "\(url?.absoluteString ?? "")|\(browser.currentTab?.isLoading == true)|\(pinned.map(\.id.uuidString).joined())|\(selected?.uuidString ?? "")|\(ui.drafts[browser.id]?.selector ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if url == nil {
                PanelEmptyState(title: "No Page Open", symbol: "text.bubble",
                                message: "Notes belong to pages. Open one to leave a note on it.")
            } else {
                toolbar
                AgentWorkingLine()
                list
                NoteComposer()
            }
        }
        .task(id: markKey) { await drawMarks() }
        // A note resolved just now (by you or an agent) stays a moment, with Undo.
        .onChange(of: ResolvedSet(site: url?.host(), ids: Set(siteResolvedIDs))) { old, new in
            guard old.site == new.site else { return }
            for id in new.ids.subtracting(old.ids) { ui.justResolved[id] = Date() }
        }
        .task(id: ui.picking.contains(browser.id)) { await pickLoop() }
        .onDisappear {
            ui.picking.remove(browser.id)
            Task { await clearPage() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            CommentToolButton()
            Menu {
                Toggle("Show Resolved", isOn: $showResolved)
                Divider()
                Button("Copy Page Notes as Markdown") { copyMarkdown() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var list: some View {
        let notes = scope == .page ? pageNotes : siteNotes
        if notes.isEmpty {
            PanelEmptyState(title: scope == .page ? "No Notes Here" : "No Notes on This Site", symbol: "text.bubble",
                            message: "Highlight text or pick something on the page with the comment tool, or right-click it and choose Add Note. Connected agents see your notes and reply here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if scope == .page {
                        ForEach(notes) { card($0) }
                    } else {
                        ForEach(groups(notes), id: \.page) { group in
                            PageGroupHeader(title: group.title, url: group.url, isCurrent: group.page == url.map(MarginStore.pageKey),
                                            count: group.notes.filter { $0.status == .open }.count)
                            ForEach(group.notes) { card($0) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .animation(Motion.snappy, value: notes.map(\.id))
            }
        }
    }

    private func card(_ note: MarginNote) -> some View {
        let number = pinned.firstIndex { $0.id == note.id }.map { $0 + 1 }
        return NoteCard(note: note, number: scope == .page || note.page == url.map(MarginStore.pageKey) ? number : nil,
                        isSelected: selected == note.id) {
            withAnimation(Motion.snappy) { selected = selected == note.id ? nil : note.id }
            if selected == note.id, let number { reveal(number) }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private struct Group { let page: String; let title: String; let url: URL?; let notes: [MarginNote] }

    /// This page first, then the rest of the site by most recent note.
    private func groups(_ notes: [MarginNote]) -> [Group] {
        let here = url.map(MarginStore.pageKey)
        let byPage = Dictionary(grouping: notes, by: \.page)
        return byPage.map { key, list in
            Group(page: key, title: list.first?.pageTitle ?? key, url: list.first.flatMap { URL(string: $0.url) }, notes: list)
        }
        .sorted { a, b in
            if a.page == here { return true }
            if b.page == here { return false }
            return (a.notes.map(\.createdAt).max() ?? .distantPast) > (b.notes.map(\.createdAt).max() ?? .distantPast)
        }
    }

    private func copyMarkdown() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(margin.markdown(for: url), forType: .string)
        browser.showToast("Copied notes as Markdown")
    }

    // MARK: The page

    private func drawMarks() async {
        guard let page = browser.currentController?.page, browser.currentTab?.isLoading != true else { return }
        var marks: [[String: Any]] = pinned.enumerated().map { i, n in
            var m: [String: Any] = ["n": i + 1, "selected": n.id == selected]
            if let q = n.anchor.quote { m["quote"] = q }
            if let s = n.anchor.selector { m["selector"] = s }
            return m
        }
        // The note being written shows too, as a pin with no number yet.
        if let d = ui.drafts[browser.id], d.url == url, d.quote != nil || d.selector != nil {
            var m: [String: Any] = ["n": "+", "selected": true]
            if let q = d.quote { m["quote"] = q }
            if let s = d.selector { m["selector"] = s }
            marks.append(m)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: marks), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await page.evaluate(MarginMarks.script + "\nreturn window.__browsaMarks(\(json));", inWorld: "browsa.margin")
    }

    private func clearPage() async {
        guard let page = browser.currentController?.page else { return }
        _ = try? await page.evaluate(MarginMarks.script + NotePicker.script + "\nwindow.__browsaPickOff(); return window.__browsaMarks([]);",
                                     inWorld: "browsa.margin")
    }

    private func reveal(_ n: Int) {
        guard let page = browser.currentController?.page else { return }
        Task { _ = try? await page.evaluate("const p = document.querySelector('.__browsa-pin[data-n=\"\(n)\"]'); p && p.scrollIntoView({block: 'center', behavior: 'smooth'}); return !!p", inWorld: "browsa.margin") }
    }

    /// While the comment tool is on: outline what's under the pointer, and take the first click or
    /// highlight as the new note's anchor. Escape on the page turns it off.
    private func pickLoop() async {
        guard ui.picking.contains(browser.id), let page = browser.currentController?.page, let url else {
            if let page = browser.currentController?.page {
                _ = try? await page.evaluate(NotePicker.script + "\nwindow.__browsaPickOff(); return true;", inWorld: "browsa.margin")
            }
            return
        }
        _ = try? await page.evaluate(NotePicker.script + "\nwindow.__browsaPickOn(); return true;", inWorld: "browsa.margin")
        while !Task.isCancelled, ui.picking.contains(browser.id) {
            try? await Task.sleep(for: .milliseconds(150))
            let raw = try? await page.evaluate(NotePicker.script + "\nreturn window.__browsaTakePick();", inWorld: "browsa.margin")
            guard let picked = raw as? [String: Any] else { continue }
            if picked["cancel"] != nil { withAnimation(Motion.snappy) { _ = ui.picking.remove(browser.id) }; break }
            ui.startDraft(from: picked, url: url, in: browser)
            break
        }
        _ = try? await page.evaluate(NotePicker.script + "\nwindow.__browsaPickOff(); return true;", inWorld: "browsa.margin")
    }
}

/// The comment tool: pick an element or highlight text on the page to start a note.
private struct CommentToolButton: View {
    @Environment(Browser.self) private var browser
    private var on: Bool { NotesUI.shared.picking.contains(browser.id) }

    var body: some View {
        Button {
            withAnimation(Motion.snappy) {
                if on { NotesUI.shared.picking.remove(browser.id) } else { NotesUI.shared.picking.insert(browser.id) }
            }
        } label: {
            Label(on ? "Picking" : "Comment", systemImage: on ? "scope" : "plus.bubble")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .foregroundStyle(on ? NoteColor.ink : .primary)
                .background(on ? AnyShapeStyle(NoteColor.pin) : AnyShapeStyle(.primary.opacity(0.07)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: [.command, .option])
        .help(on ? "Click something or highlight text on the page. Esc to stop." : "Comment on something on the page (⌥⌘N)")
    }
}

/// "Claude Code is on it": an agent's calls are touching this page right now.
private struct AgentWorkingLine: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if let agent = browser.library.agents.working(on: browser.currentTab?.url) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("\(agent) is working on this page").font(.caption).foregroundStyle(.purple)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.purple.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: browser.library.agents.working(on: browser.currentTab?.url))
    }
}

private struct PageGroupHeader: View {
    @Environment(Browser.self) private var browser
    let title: String
    let url: URL?
    let isCurrent: Bool
    let count: Int

    var body: some View {
        Button {
            guard let url, !isCurrent else { return }
            if let tab = browser.library.allTabs.first(where: { $0.url.map(MarginStore.pageKey) == MarginStore.pageKey(url) }) {
                browser.select(tab)
            } else {
                browser.newTab(url: url)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(url?.path() ?? "").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent { Text("This page").font(.system(size: 10)).foregroundStyle(.secondary) }
                else { Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.top, 8).padding(.horizontal, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "" : "Go to this page")
    }
}

// MARK: - Composer

/// One slim field. What the note points at sits above it as a chip; Add appears once there's text.
private struct NoteComposer: View {
    @Environment(Browser.self) private var browser
    @State private var text = ""
    @FocusState private var focused: Bool
    private var ui: NotesUI { .shared }
    private var draft: NoteDraft? { ui.drafts[browser.id] }
    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let draft, draft.url == browser.currentTab?.url, draft.quote != nil || draft.selector != nil {
                AnchorChip(draft: draft) { withAnimation(Motion.snappy) { _ = ui.drafts.removeValue(forKey: browser.id) } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(draft == nil ? "Add a note…" : "What about it?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(add)
                    .onKeyPress(.escape) {
                        guard draft != nil || !text.isEmpty else { return .ignored }
                        withAnimation(Motion.snappy) { text = ""; ui.drafts.removeValue(forKey: browser.id) }
                        return .handled
                    }
                    .padding(.vertical, 2)
                if canAdd {
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.background.opacity(focused ? 1 : 0.6), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.primary.opacity(0.1)),
                                  lineWidth: focused ? 1.5 : 1)
            }
            .animation(Motion.snappy, value: canAdd)
            .animation(Motion.snappy, value: focused)
        }
        .padding(10)
        .onChange(of: ui.focusRequests[browser.id]) { focused = true }
    }

    private func add() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let url = browser.currentTab?.url, let tab = browser.currentTab else { return }
        let anchor = draft?.url == url ? draft?.anchor ?? .init() : .init()
        withAnimation(Motion.snappy) {
            browser.library.margin.add(MarginNote(url: url, pageTitle: tab.title, anchor: anchor, body: body))
            ui.drafts.removeValue(forKey: browser.id)
            text = ""
        }
    }
}

private struct AnchorChip: View {
    let draft: NoteDraft
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: draft.quote != nil ? "text.quote" : "scope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NoteColor.ink)
                .frame(width: 18, height: 18)
                .background(NoteColor.pin, in: .circle)
            Text(draft.quote.map { "“\($0)”" } ?? draft.label ?? draft.selector ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: clear) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Don't pin to this")
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
        .background(NoteColor.pin.opacity(0.14), in: .capsule)
    }
}

// MARK: - Card

/// One note. Quiet until you hover or pick it; then Reply and Resolve show. Replies sit flush
/// under the note, one thread, no indent.
private struct NoteCard: View {
    @Environment(Browser.self) private var browser
    let note: MarginNote
    let number: Int?
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false
    @State private var replying = false

    private var margin: MarginStore { browser.library.margin }
    private var ui: NotesUI { .shared }
    private var showsActions: Bool { hovering || isSelected || replying }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    header(author: note.author, date: note.createdAt, number: number)
                    if let q = note.anchor.quote {
                        Text(q).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Capsule().fill(NoteColor.pin.opacity(0.8)).frame(width: 2) }
                    } else if let s = note.anchor.selector {
                        Label(s, systemImage: "scope").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(note.body).font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ForEach(note.replies) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Divider().opacity(0.6)
                    header(author: r.author, date: r.createdAt, number: nil)
                    Text(r.body).font(.callout).textSelection(.enabled)
                }
            }

            if let at = ui.justResolved[note.id], note.status == .resolved {
                ResolvedLine(by: note.resolvedBy ?? .you, at: at) {
                    withAnimation(Motion.snappy) { margin.reopen(note.id); _ = ui.justResolved.removeValue(forKey: note.id) }
                }
                .transition(.opacity)
            } else if replying {
                ReplyBar(isOpen: $replying) { text in
                    withAnimation(Motion.snappy) { margin.reply(to: note.id, author: .you, body: text) }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity))
            } else if showsActions {
                HStack(spacing: 14) {
                    Button { withAnimation(Motion.snappy) { replying = true } } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if note.status == .open {
                        Button {
                            withAnimation(Motion.snappy) {
                                margin.resolve(note.id, by: .you)
                            }
                        } label: { Label("Resolve", systemImage: "checkmark.circle").font(.caption.weight(.medium)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    } else {
                        Button("Reopen") { withAnimation(Motion.snappy) { margin.reopen(note.id) } }
                            .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(.primary.opacity(note.status == .open ? (isSelected ? 0.075 : 0.05) : 0.03), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(NoteColor.pin.opacity(0.75)) : AnyShapeStyle(.clear), lineWidth: 1.5)
        }
        .opacity(note.status == .resolved && ui.justResolved[note.id] == nil ? 0.7 : 1)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .contextMenu {
            Button("Delete Note", role: .destructive) { margin.delete(note.id) }
        }
    }

    private func header(author: MarginNote.Author, date: Date, number: Int?) -> some View {
        HStack(spacing: 6) {
            if let number { PinBadge(number: number) }
            AuthorBadge(author: author)
            Text(Self.short(date)).font(.caption2).foregroundStyle(.tertiary)
                .help(date.formatted(date: .abbreviated, time: .shortened))
            Spacer(minLength: 0)
            if author == note.author, note.status == .resolved, ui.justResolved[note.id] == nil {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).help("Resolved")
            }
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

/// Reply opens into its own clean field, focused, with Add on the right once there's text.
/// Return sends, Escape closes.
private struct ReplyBar: View {
    @Binding var isOpen: Bool
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Reply…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.escape) { withAnimation(Motion.snappy) { isOpen = false }; return .handled }
                .padding(.vertical, 2)
            Button("Add", action: submit)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.5)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0.3), lineWidth: focused ? 1.5 : 1)
        }
        .animation(Motion.snappy, value: focused)
        .onAppear { focused = true }
        .onChange(of: focused) { _, f in
            // Clicking away from an empty reply closes it.
            if !f, text.isEmpty { withAnimation(Motion.snappy) { isOpen = false } }
        }
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        send(body)
        text = ""
        withAnimation(Motion.snappy) { isOpen = false }
    }
}

private struct ResolvedLine: View {
    let by: MarginNote.Author
    let at: Date
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(by == .you ? "Resolved" : "Resolved by \(by.name)").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Undo", action: undo).buttonStyle(.plain).foregroundStyle(Color.accentColor).fontWeight(.medium)
        }
        .font(.caption)
        .task {
            // Leaves after a few seconds; Show Resolved brings it back.
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Motion.snappy) { NotesUI.shared.justResolved = NotesUI.shared.justResolved.filter { $0.value != at } }
        }
    }
}

struct PinBadge: View {
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(NoteColor.ink)
            .frame(width: 16, height: 16)
            .background(NoteColor.pin, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 2,
                                                                 bottomTrailingRadius: 8, topTrailingRadius: 8))
            .help("Pin \(number) on the page")
    }
}

private struct AuthorBadge: View {
    let author: MarginNote.Author
    var body: some View {
        switch author {
        case .you: Text("You").font(.caption.weight(.semibold))
        case .agent(let name):
            Label { Text(name) } icon: { AgentIcon(caller: name, size: 12) }
                .font(.caption.weight(.semibold)).foregroundStyle(.purple)
        }
    }
}

/// Open notes on a tab's page, for the yellow count on its row.
@MainActor
func openNoteCount(_ url: URL?, in library: Library) -> Int {
    guard let url else { return 0 }
    return library.margin.notes(on: url).filter { $0.status == .open }.count
}

// MARK: - Page scripts

/// The comment tool on the page: an outline follows the pointer, a click picks the element, a
/// highlight picks the text. Runs in Browsa's own world, out of the page's reach.
enum NotePicker {
    // Each evaluate gets fresh globals, so state lives on the page: flags in data attributes on
    // <html>, listeners bound once and gated on them.
    static let script = #"""
    const root = document.documentElement;
    const describe = (el) => {
      if (!el || el === document.body || el === root) return null;
      const sel = (e) => {
        if (e.id) return '#' + CSS.escape(e.id);
        const parts = [];
        for (let n = e; n && n !== document.body && parts.length < 5; n = n.parentElement) {
          if (n.id) { parts.unshift('#' + CSS.escape(n.id)); break; }
          let s = n.tagName.toLowerCase();
          const sib = n.parentElement ? [...n.parentElement.children].filter(c => c.tagName === n.tagName) : [];
          if (sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(n) + 1) + ')';
          parts.unshift(s);
        }
        return parts.join(' > ');
      };
      const r = el.getBoundingClientRect();
      const text = ((el.labels && el.labels[0] && el.labels[0].innerText) || el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().replace(/\s+/g, ' ').slice(0, 40);
      const kind = { BUTTON: 'button', A: 'link', INPUT: 'field', TEXTAREA: 'field', SELECT: 'menu', IMG: 'image', H1: 'heading', H2: 'heading', H3: 'heading', LABEL: 'label' }[el.tagName] || 'element';
      return { selector: sel(el), label: text ? text + ' ' + kind : kind, x: r.left + scrollX, y: r.top + scrollY };
    };
    window.__browsaDescribe = (x, y) => {
      const q = String(getSelection() || '').trim();
      if (q) return { quote: q.slice(0, 500) };
      return describe(document.elementFromPoint(x, y));
    };
    const box = () => {
      let b = document.getElementById('__browsa-pick-box');
      if (!b) {
        b = document.createElement('div'); b.id = '__browsa-pick-box';
        Object.assign(b.style, { position: 'absolute', zIndex: 2147483645, pointerEvents: 'none', border: '2px solid #f5b60b',
          background: 'rgba(250,204,21,.12)', borderRadius: '6px', transition: 'all .08s ease-out', display: 'none' });
        document.body.appendChild(b);
      }
      return b;
    };
    const on = () => root.dataset.browsaPicking === '1';
    const put = (v) => { root.dataset.browsaPicked = JSON.stringify(v); };
    window.__browsaPickOn = () => {
      root.dataset.browsaPicking = '1';
      root.style.cursor = 'crosshair';
      if (root.dataset.browsaPickBound) return;
      root.dataset.browsaPickBound = '1';
      addEventListener('mousemove', (e) => {
        if (!on() || !e.target || e.target.id === '__browsa-pick-box') return;
        const r = e.target.getBoundingClientRect();
        Object.assign(box().style, { display: 'block', left: (r.left + scrollX - 3) + 'px', top: (r.top + scrollY - 3) + 'px',
          width: (r.width + 6) + 'px', height: (r.height + 6) + 'px' });
      }, true);
      addEventListener('mouseup', () => {
        if (!on()) return;
        const q = String(getSelection() || '').trim();
        if (q) put({ quote: q.slice(0, 500) });
      }, true);
      addEventListener('click', (e) => {
        if (!on() || String(getSelection() || '').trim()) return;
        e.preventDefault(); e.stopPropagation();
        put(describe(e.target));
      }, true);
      addEventListener('keydown', (e) => { if (on() && e.key === 'Escape') put({ cancel: true }); }, true);
    };
    window.__browsaPickOff = () => {
      delete root.dataset.browsaPicking;
      root.style.cursor = '';
      const b = document.getElementById('__browsa-pick-box'); if (b) b.remove();
    };
    window.__browsaTakePick = () => {
      const v = root.dataset.browsaPicked; if (!v) return null;
      delete root.dataset.browsaPicked;
      try { return JSON.parse(v); } catch (e) { return null; }
    };
    """#
}

enum MarginMarks {
    static let script = #"""
    if (!window.__browsaMarks) {
      window.__browsaMarks = (marks) => {
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
        // Globals don't outlive one evaluate, so the last marks and the bound flag live on <html>.
        document.documentElement.dataset.browsaMarks = JSON.stringify(marks);
        if (!document.documentElement.dataset.browsaResizeBound) {
          document.documentElement.dataset.browsaResizeBound = '1';
          const redraw = window.__browsaMarks;
          addEventListener('resize', () => redraw(JSON.parse(document.documentElement.dataset.browsaMarks || '[]')));
        }
        return marks.length;
      };
    }
    """#
}
