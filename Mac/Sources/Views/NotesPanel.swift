import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine
import Extensibility
import WebKitEngine

/// Yellow, like a sticky note: it reads as "a note" on any site. Agents acting live share it.
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

    /// The comment tool stays on after each note (the switch above the composer).
    var staysInCommentMode = Preferences.notesStayInCommentMode {
        didSet { Preferences.notesStayInCommentMode = staysInCommentMode }
    }

    /// Windows whose keyboard is in the Notes composer. There the comment tool's key works the tool
    /// (picking hands the keyboard to the composer, and the next press is usually for another pick).
    var composerFocused: Set<UUID> = []

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
    /// The last pick came from a pin on the page: its reply opens without taking the keyboard,
    /// so you can keep clicking around the page.
    @State private var pickedFromPage = false
    /// A note picked on another page, to scroll to once that page has loaded.
    @State private var revealAfterLoad: UUID?
    /// The page the marks were last drawn on.
    @State private var markedPage: (any EnginePage)?

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

    /// The panel stays alive while closed (it slides away), so marks follow whether Notes is showing.
    private var isShowing: Bool { browser.panel == "notes" }

    private var markKey: String {
        "\(isShowing)|\(url?.absoluteString ?? "")|\(browser.currentTab?.isLoading == true)|\(pinned.map(\.id.uuidString).joined())|\(selected?.uuidString ?? "")|\(ui.drafts[browser.id]?.selector ?? "")"
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
        .task(id: "\(isShowing)|\(url?.absoluteString ?? "")") { await pinClickLoop() }
        .onChange(of: isShowing) { _, showing in
            if !showing { ui.picking.remove(browser.id) }
        }
        .onDisappear {
            ui.picking.remove(browser.id)
            Task { await clearPage() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Next to the page, where your eye already is.
            CommentToolButton()
            Spacer(minLength: 0)
            ScopeSwitch(scope: $scope)
            Menu {
                Toggle("Show Resolved", isOn: $showResolved)
                Divider()
                Button("Copy Page Notes as Markdown") { copyMarkdown() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
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
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
                .frame(maxWidth: .infinity, alignment: .top)
            }
            // A click on the panel's empty space puts the picked note down.
            .background {
                Color.clear.contentShape(.rect)
                    .onTapGesture { withAnimation(Motion.snappy) { selected = nil } }
            }
            // A note picked from its pin on the page scrolls into view here.
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
            }
        }
    }

    private func card(_ note: MarginNote) -> some View {
        let number = pinned.firstIndex { $0.id == note.id }.map { $0 + 1 }
        return NoteCard(note: note, number: scope == .page || note.page == url.map(MarginStore.pageKey) ? number : nil,
                        isSelected: selected == note.id, focusesReply: !pickedFromPage, deselect: {
            if selected == note.id { withAnimation(Motion.snappy) { selected = nil } }
        }) {
            pickedFromPage = false
            // A note on another page of the site takes you there, then picks it once the page is up.
            if note.page != url.map(MarginStore.pageKey), let target = URL(string: note.url) {
                withAnimation(Motion.snappy) { selected = note.id }
                revealAfterLoad = note.id
                go(to: target, in: browser)
                return
            }
            // Always picks, never toggles off: clicking empty panel space puts it down.
            withAnimation(Motion.snappy) { selected = note.id }
            if let number { reveal(number) }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .id(note.id)
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
        // Switching tabs leaves the old page's marks behind otherwise.
        if let old = markedPage, old !== page {
            _ = try? await old.evaluate(MarginMarks.script + "\nreturn window.__browsaMarks([]);", inWorld: "browsa.margin")
        }
        markedPage = page
        guard isShowing else {
            _ = try? await page.evaluate(MarginMarks.script + NotePicker.script + "\nwindow.__browsaPickOff(); return window.__browsaMarks([]);",
                                         inWorld: "browsa.margin")
            return
        }
        var marks: [[String: Any]] = pinned.enumerated().map { i, n in
            var m: [String: Any] = ["n": i + 1, "selected": n.id == selected]
            if let q = n.anchor.quote { m["quote"] = q }
            if let s = n.anchor.selector { m["selector"] = s }
            if let x = n.anchor.x, let y = n.anchor.y { m["x"] = x; m["y"] = y }
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
        if let id = revealAfterLoad, let i = pinned.firstIndex(where: { $0.id == id }) {
            revealAfterLoad = nil
            reveal(i + 1)
        }
    }

    private func clearPage() async {
        guard let page = browser.currentController?.page else { return }
        _ = try? await page.evaluate(MarginMarks.script + NotePicker.script + "\nwindow.__browsaPickOff(); return window.__browsaMarks([]);",
                                     inWorld: "browsa.margin")
    }

    /// Clicking a pin on the page picks its note here, which opens its reply.
    private func pinClickLoop() async {
        guard isShowing, let page = browser.currentController?.page else { return }
        while !Task.isCancelled, isShowing {
            try? await Task.sleep(for: .milliseconds(200))
            let raw = try? await page.evaluate(
                "const r = document.documentElement; const n = r.dataset.browsaPinClicked; delete r.dataset.browsaPinClicked; return n || null;",
                inWorld: "browsa.margin")
            guard let n = (raw as? String).flatMap(Int.init), pinned.indices.contains(n - 1) else { continue }
            let id = pinned[n - 1].id
            pickedFromPage = true
            withAnimation(Motion.snappy) { selected = id }
        }
    }

    private func reveal(_ n: Int) {
        guard let page = browser.currentController?.page else { return }
        Task { _ = try? await page.evaluate("document.dispatchEvent(new CustomEvent('browsa-reveal', { detail: \(n) })); return true", inWorld: "browsa.margin") }
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

/// This Page / This Site, as a glass capsule with the choice riding in it.
private struct ScopeSwitch: View {
    @Binding var scope: MarginPanel.Scope
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MarginPanel.Scope.allCases, id: \.self) { s in
                Button { withAnimation(Motion.snappy) { scope = s } } label: {
                    Text(s.rawValue)
                        .font(.system(size: 11, weight: scope == s ? .semibold : .medium))
                        .foregroundStyle(scope == s ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if scope == s {
                                Capsule().fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "scope", in: ns)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show notes on")
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
        .help(on ? "Click something or highlight text on the page. Esc to stop." : Shortcuts.shared.help("Comment on something on the page", .comment))
    }
}

/// "Claude Code is on it": an agent's calls are touching this page right now.
private struct AgentWorkingLine: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if let agent = browser.library.agents.working(on: browser.currentTab?.url) {
                HStack(spacing: 8) {
                    Circle().fill(AgentLive.color).frame(width: 7, height: 7).symbolEffect(.pulse)
                    Text("\(AgentIdentity.displayName(agent)) is working on this page").font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                // Inset like the cards below it, not edge to edge.
                .background(AgentLive.color.opacity(0.08), in: .rect(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 10).padding(.bottom, 6)
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
            go(to: url, in: browser)
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
    private var picking: Bool { ui.picking.contains(browser.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if picking || (ui.staysInCommentMode && draft != nil) {
                CommentModeRow(picking: picking)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
                    .onKeyPress(.return, phases: .down) { press in newLine(press) }
                    .onKeyPress(.escape) {
                        guard draft != nil || !text.isEmpty else { return .ignored }
                        withAnimation(Motion.snappy) { text = ""; ui.drafts.removeValue(forKey: browser.id) }
                        return .handled
                    }
                    .padding(.vertical, 2)
                // Always laid out, shown once there's text: the field keeps one width, so a line that
                // wrapped before Add appeared isn't cut off by it.
                Button("Add", action: add)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0)
                    .scaleEffect(canAdd ? 1 : 0.8)
                    .accessibilityHidden(!canAdd)
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
        .animation(Motion.snappy, value: picking)
        .onChange(of: ui.focusRequests[browser.id]) { focused = true }
        .onChange(of: focused) { _, on in
            if on { ui.composerFocused.insert(browser.id) } else { ui.composerFocused.remove(browser.id) }
        }
        .onDisappear { ui.composerFocused.remove(browser.id) }
    }

    private func add() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let url = browser.currentTab?.url, let tab = browser.currentTab else { return }
        let anchor = draft?.url == url ? draft?.anchor ?? .init() : .init()
        let commented = draft != nil
        withAnimation(Motion.snappy) {
            browser.library.margin.add(MarginNote(url: url, pageTitle: tab.title, anchor: anchor, body: body))
            ui.drafts.removeValue(forKey: browser.id)
            text = ""
            // A run of comments: straight back to picking the next thing.
            if commented, ui.staysInCommentMode { ui.picking.insert(browser.id) }
        }
    }
}

/// While the comment tool is on: what to do, and whether it stays on after each note.
private struct CommentModeRow: View {
    let picking: Bool

    var body: some View {
        @Bindable var ui = NotesUI.shared
        HStack(spacing: 8) {
            Text(picking ? "Click or highlight something. Esc to stop." : "Return adds it, then pick the next.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Toggle("Stay", isOn: $ui.staysInCommentMode)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.caption).foregroundStyle(.secondary)
                .help("Stay in comment mode after each note, to comment on one thing after another")
        }
        .padding(.horizontal, 4)
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
    /// Whether opening the reply puts the cursor in it (not when picked from a pin on the page).
    let focusesReply: Bool
    /// Puts the card down: one state for "active", ring and reply together.
    let deselect: () -> Void
    let select: () -> Void
    @State private var hovering = false
    @State private var replying = false
    @State private var focusRequest = 0

    private var margin: MarginStore { browser.library.margin }
    private var ui: NotesUI { .shared }
    private var showsActions: Bool { hovering || isSelected || replying }

    /// The one thing a click anywhere on the card does: pick it, with its reply open.
    private func pick() {
        select()
        guard note.status == .open else { return }
        withAnimation(Motion.snappy) { replying = true }
        // A click on the card always puts the cursor in the reply, whether the field is new or was
        // already open (say, from a pin). Asked for once the field exists.
        DispatchQueue.main.async { focusRequest += 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 7) {
                    header(author: note.author, date: note.createdAt, number: number)
                    if let q = note.anchor.quote {
                        Text(q).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Capsule().fill(NoteColor.pin.opacity(0.8)).frame(width: 2) }
                    } else if let s = note.anchor.selector {
                        Label(s, systemImage: "scope").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(note.body).font(.system(size: 13)).lineSpacing(1.5)
                    ForEach(note.replies) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Divider().opacity(0.6)
                            header(author: r.author, date: r.createdAt, number: nil)
                            Text(r.body).font(.system(size: 13)).lineSpacing(1.5)
                        }
                        .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if let at = ui.justResolved[note.id], note.status == .resolved {
                ResolvedLine(by: note.resolvedBy ?? .you, at: at) {
                    withAnimation(Motion.snappy) { margin.reopen(note.id); _ = ui.justResolved.removeValue(forKey: note.id) }
                }
                .transition(.opacity)
            } else if replying {
                ReplyBar(isOpen: $replying, autofocus: focusesReply, focusRequest: focusRequest) { text in
                    withAnimation(Motion.snappy) { margin.reply(to: note.id, author: .you, body: text) }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity))
            } else if showsActions {
                HStack(spacing: 14) {
                    Button(action: pick) {
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
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        // The card's padding and gaps pick it too, so there's no dead area.
        .background {
            Button(action: pick) { Color.clear.contentShape(.rect) }.buttonStyle(.plain)
        }
        // White in light, black in dark, lifted off the panel by a hairline and a soft shadow.
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(NoteColor.pin.opacity(0.8)) : AnyShapeStyle(.primary.opacity(0.08)),
                              lineWidth: isSelected ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(isSelected ? 0.10 : 0.05), radius: isSelected ? 6 : 3, y: 1)
        .opacity(note.status == .resolved && ui.justResolved[note.id] == nil ? 0.7 : 1)
        // Picking a note opens its reply; picking another, or clicking away, closes it.
        .onChange(of: isSelected) { _, selected in
            withAnimation(Motion.snappy) { replying = selected && note.status == .open }
        }
        .onAppear { if isSelected, note.status == .open { replying = true } }
        // Closing the reply (Esc, the close button, sending, or clicking away) puts the card down too.
        .onChange(of: replying) { _, open in
            if !open, isSelected { deselect() }
        }
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
    var autofocus = true
    /// Bumped by a click on the card: focus the field.
    var focusRequest = 0
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
                .onKeyPress(.return, phases: .down) { press in newLine(press) }
                .onKeyPress(.escape) { withAnimation(Motion.snappy) { isOpen = false }; return .handled }
                .padding(.vertical, 2)
            // Nothing typed yet: a quiet close. Once there's text: Add.
            if canSend {
                Button("Add", action: submit)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                Button { withAnimation(Motion.snappy) { isOpen = false } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.07), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: canSend)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0.3), lineWidth: focused ? 1.5 : 1)
        }
        .animation(Motion.snappy, value: focused)
        .onAppear { if autofocus { focused = true } }
        .onChange(of: focusRequest) { focused = true }
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
            Label { Text(AgentIdentity.displayName(name)) } icon: { AgentIcon(caller: name, size: 12) }
                .font(.caption.weight(.semibold))
        }
    }
}

/// Goes to a page: its open tab if there is one, in any space, else a new tab. Notes stays open.
@MainActor
func go(to url: URL, in browser: Browser) {
    let key = MarginStore.pageKey(url)
    withAnimation(Motion.snappy) {
        if let tab = browser.library.allTabs.first(where: { $0.url.map(MarginStore.pageKey) == key }) {
            browser.select(tab)
        } else {
            browser.newTab(url: url)
        }
    }
    if browser.panel != "notes" { browser.showPanel("notes") }
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
    /// Whether the keyboard is in something you type in on the page: a field, an editor, a terminal
    /// (they sit on a hidden text area), or a frame, which can't be seen into and gets the benefit of the doubt.
    static let isTypingScript = #"""
    let a = document.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    if (!a || a === document.body || a === document.documentElement) return false;
    if (['IFRAME', 'FRAME', 'EMBED', 'OBJECT', 'TEXTAREA', 'SELECT'].includes(a.tagName)) return true;
    if (a.isContentEditable || a.getAttribute('role') === 'textbox') return true;
    if (a.tagName === 'INPUT') return !['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'image', 'range', 'color'].includes((a.type || 'text').toLowerCase());
    return false;
    """#

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

/// Draws the open notes on the page: a numbered pin at each anchor, a highlight on quoted text, a box round a
/// pinned element.
///
/// Pages change under the pins, so they're kept up to date rather than drawn once: they sit in their own layer on
/// `<html>` (a page re-rendering its `<body>` can't wipe them), follow their anchors through scrolling (sticky
/// headers and scrolling panels too) and resizing, and an anchor that wasn't on the page yet (a page still
/// rendering, content loaded later) is looked for again as the page changes. Quotes match across links and bold
/// text and ignore differences in spacing.
///
/// Every evaluate can start with fresh globals, so the drawing lives in listeners bound once per page, and each
/// call hands them the marks through a data attribute and an event.
enum MarginMarks {
    static let script = #"""
    if (!window.__browsaMarks) {
      window.__browsaMarks = (marks) => {
        const root = document.documentElement;
        root.dataset.browsaMarks = JSON.stringify(marks);
        if (!root.dataset.browsaMarksBound) {
          root.dataset.browsaMarksBound = '1';
          let anchors = [], frame = 0, refind = 0, observer = null;
          const layer = () => {
            let l = document.getElementById('__browsa-marks');
            if (!l) {
              l = document.createElement('div');
              l.id = '__browsa-marks';
              l.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;overflow:visible;z-index:2147483646;pointer-events:none;contain:layout style;';
              // Highlights need a style sheet. A constructed one, since many sites' Content Security Policy
              // (browsa.app's own, for one) blocks a <style> element; everything else is styled inline.
              try {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync('::highlight(browsa-note) { background-color: rgba(250, 204, 21, .32); }' +
                  '::highlight(browsa-note-selected) { background-color: rgba(250, 204, 21, .62); }');
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
              } catch (e) {}
            }
            if (l.parentNode !== root) root.appendChild(l);
            return l;
          };
          // The page's text as one string with spacing collapsed, mapped back to text nodes, so a quote is
          // found even when it runs across a link or bold text.
          const findText = (quote) => {
            const want = quote.replace(/\s+/g, ' ').trim();
            if (!want || !document.body) return null;
            const nodes = [], offsets = [], chars = [];
            let lastSpace = true;
            const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
              acceptNode: (t) => t.parentElement && !t.parentElement.closest('script,style,noscript,#__browsa-marks')
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT });
            for (let t = w.nextNode(); t; t = w.nextNode()) {
              const d = t.data;
              for (let i = 0; i < d.length; i++) {
                const c = d.charCodeAt(i), space = c <= 32 || c === 160;
                if (space && lastSpace) continue;
                lastSpace = space;
                chars.push(space ? ' ' : d[i]); nodes.push(t); offsets.push(i);
              }
            }
            const text = chars.join('');
            let at = text.indexOf(want);
            if (at < 0) at = text.toLowerCase().indexOf(want.toLowerCase());
            if (at < 0) return null;
            const last = at + want.length - 1;
            const r = document.createRange();
            r.setStart(nodes[at], offsets[at]); r.setEnd(nodes[last], offsets[last] + 1);
            return r;
          };
          // A note whose quote or element isn't on the page keeps a pin where it was made, if that's known.
          const connected = (a) => a.range ? a.range.startContainer.isConnected && !a.range.collapsed
            : a.el ? a.el.isConnected : false;
          const placed = (a) => connected(a) || a.point;
          // Finds each mark's anchor, keeping ones already found that are still on the page.
          const find = () => {
            const marks = JSON.parse(root.dataset.browsaMarks || '[]');
            const old = anchors;
            anchors = marks.map((m, i) => {
              const was = old[i];
              if (was && was.key === JSON.stringify([m.quote, m.selector]) && connected(was)) return Object.assign(was, { m });
              const a = { m, key: JSON.stringify([m.quote, m.selector]), range: null, el: null };
              if (m.quote) a.range = findText(m.quote);
              if (!a.range && m.selector) { try { a.el = document.querySelector(m.selector); } catch (e) {} }
              if (!a.range && !a.el && typeof m.x === 'number' && typeof m.y === 'number') a.point = { x: m.x, y: m.y };
              return a;
            });
            draw();
          };
          // Puts each pin (and box) on its anchor, in window coordinates, so they track sticky and scrolling content.
          const draw = () => {
            frame = 0;
            const l = layer();
            l.querySelectorAll('.__browsa-pin, .__browsa-box').forEach(e => e.remove());
            const plain = [], chosen = [];
            for (const a of anchors) {
              const m = a.m;
              if (!placed(a)) continue;
              const rect = a.range ? a.range.getBoundingClientRect() : a.el ? a.el.getBoundingClientRect()
                : { left: a.point.x - scrollX, top: a.point.y - scrollY, right: a.point.x - scrollX + 1,
                    bottom: a.point.y - scrollY + 1, width: 1, height: 1 };
              if (a.range) (m.selected ? chosen : plain).push(a.range);
              if (rect.width === 0 && rect.height === 0) continue;
              if (rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) continue;
              if (a.el) {
                const b = document.createElement('div');
                b.className = '__browsa-box' + (m.selected ? ' sel' : '');
                Object.assign(b.style, { position: 'fixed', pointerEvents: 'none', borderRadius: '6px',
                  border: '1.5px ' + (m.selected ? 'solid' : 'dashed') + ' rgba(245,182,11,.9)',
                  background: m.selected ? 'rgba(250,204,21,.10)' : 'none',
                  left: (rect.left - 4) + 'px', top: (rect.top - 4) + 'px',
                  width: (rect.width + 8) + 'px', height: (rect.height + 8) + 'px' });
                l.appendChild(b);
              }
              const p = document.createElement('div');
              p.className = '__browsa-pin' + (m.selected ? ' sel' : '');
              p.dataset.n = m.n; p.textContent = m.n;
              if (typeof m.n === 'number') {
                p.title = 'Show note ' + m.n;
                // On mousedown, not click: picking a note redraws the pins, and a click on a pin
                // that has been replaced in between would never arrive.
                p.addEventListener('mousedown', (e) => {
                  e.preventDefault(); e.stopPropagation();
                  root.dataset.browsaPinClicked = String(m.n);
                }, true);
                p.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); }, true);
              }
              Object.assign(p.style, { position: 'fixed', pointerEvents: 'auto', cursor: 'pointer', width: '20px', height: '20px',
                boxSizing: 'border-box', margin: '0', padding: '0', borderRadius: '10px 10px 10px 2px', background: '#f5b60b',
                color: '#1d1600', font: '600 11px/20px -apple-system, system-ui', textAlign: 'center',
                transform: 'translate(-4px, -22px)' + (m.selected ? ' scale(1.18)' : ''),
                boxShadow: (m.selected ? '0 0 0 3px rgba(245,182,11,.35), ' : '') + '0 1px 3px rgba(0,0,0,.25)',
                left: rect.left + 'px', top: rect.top + 'px' });
              l.appendChild(p);
            }
            if (window.CSS && CSS.highlights && window.Highlight) {
              CSS.highlights.delete('browsa-note'); CSS.highlights.delete('browsa-note-selected');
              if (plain.length) CSS.highlights.set('browsa-note', new Highlight(...plain));
              if (chosen.length) CSS.highlights.set('browsa-note-selected', new Highlight(...chosen));
            }
          };
          const soon = () => { if (!frame) frame = requestAnimationFrame(draw); };
          addEventListener('scroll', soon, { capture: true, passive: true });
          addEventListener('resize', soon);
          // The page changing: anchors that went missing (or never showed) are looked for again, at most a few
          // times a second, and only while some are missing; otherwise the pins just move with the layout.
          observer = new MutationObserver((records) => {
            if (records.every(r => r.target.closest && r.target.closest('#__browsa-marks'))) return;
            if (!anchors.length) return;
            if (anchors.some(a => !connected(a))) {
              if (!refind) refind = setTimeout(() => { refind = 0; find(); }, 400);
            } else soon();
          });
          observer.observe(root, { childList: true, subtree: true, characterData: true });
          document.addEventListener('browsa-marks', find);
          document.addEventListener('browsa-reveal', (e) => {
            const a = anchors.find(x => x.m.n === e.detail);
            const target = a && (a.el || (a.range && a.range.startContainer.parentElement));
            if (target) target.scrollIntoView({ block: 'center', behavior: 'smooth' });
          });
        }
        document.dispatchEvent(new CustomEvent('browsa-marks'));
        return marks.length;
      };
    }
    """#
}

/// Return sends. Shift-Return (what most apps and the web use) and Option-Return (the AppKit
/// convention) both start a new line, at the cursor.
@MainActor
private func newLine(_ press: KeyPress) -> KeyPress.Result {
    guard press.modifiers.contains(.shift) || press.modifiers.contains(.option) else { return .ignored }
    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
    return .handled
}

extension Browser {
    /// Notes is in the workbench and there's a web page to comment on.
    var canComment: Bool {
        library.workbench.tool("notes") != nil && currentTab?.url?.scheme?.hasPrefix("http") == true
    }

    /// ⌥C: turns the comment tool on (opening Notes for it) or off.
    func toggleCommentMode() {
        guard canComment else { return }
        let ui = NotesUI.shared
        withAnimation(Motion.snappy) {
            if ui.picking.contains(id) { ui.picking.remove(id); return }
            if panel != "notes" { showPanel("notes") }
            ui.picking.insert(id)
        }
    }
}
