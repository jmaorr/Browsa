import SwiftUI
import AppKit
import Observation
import BrowserCore
import Suggest

/// Drives the command bar: recent tabs and top sites until you type, then streamed suggestions.
/// The same logic as the iPhone app's new-tab sheet.
@MainActor @Observable
final class CommandBarModel {
    /// What was actually typed, never the inline completion's tail.
    private(set) var typed = ""
    private(set) var zero: ZeroState?
    private(set) var results: SuggestResults?
    private(set) var highlighted: Int?

    var inline: InlineCompletion? { results?.inline }
    var isTyping: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty }

    var rows: [Suggestion] {
        if commandSource != nil { return commandRows }
        if isTyping {
            guard let r = results else { return [] }
            let primary = r.primary.map { [$0] } ?? []
            // Without an inline completion, Return searches, so that row leads, like Arc.
            return r.inline == nil ? primary + r.local + r.remote : r.local + primary + r.remote
        }
        guard let zero else { return [] }
        let rows = zero.recentTabs.map(Self.row(for:)) + zero.topSites
        // Nothing open or visited yet: offer the favourites, so the bar never opens empty.
        return rows.isEmpty ? zero.favorites.map {
            Suggestion(kind: .favorite, title: $0.title.isEmpty ? $0.displayName : $0.title,
                       subtitle: URLNormalizer.displayHost($0.url), action: .open($0.url), score: 0)
        } : rows
    }

    static func row(for t: OpenTabSnapshot) -> Suggestion {
        Suggestion(kind: .openTab, title: t.title.isEmpty ? URLNormalizer.displayHost(t.url) : t.title,
                   subtitle: URLNormalizer.displayHost(t.url), action: .switchToTab(id: t.id, url: t.url), score: 0)
    }

    private let engine: SuggestEngine
    private let isPrivate: Bool
    /// Set in ⌘K mode: rows come from these commands, matched here, not from the suggest engine.
    private let commandSource: (@MainActor () -> [BrowserCommand])?
    /// Commands shown before you type in ⌘K mode, by id, in order.
    private let featured: [String]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: SuggestEngine, isPrivate: Bool, commands: (@MainActor () -> [BrowserCommand])? = nil, featured: [String] = []) {
        self.engine = engine
        self.isPrivate = isPrivate
        self.commandSource = commands
        self.featured = featured
    }

    /// ⌘K: commands that match, best first, then searching the web as a way out.
    private var commandRows: [Suggestion] {
        let all = commandSource?() ?? []
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return featured.compactMap { byID[$0] }.map(Self.row(for:))
        }
        let matched = all.compactMap { c -> Suggestion? in
            var quality = Matcher.titleQuality(query: q, title: c.title, keywords: c.keywords)
            if quality == .none, c.title.localizedCaseInsensitiveContains(q) { quality = .substring }
            guard quality != .none else { return nil }
            return Suggestion(kind: .command, title: c.title, subtitle: c.subtitle, action: .command(id: c.id), score: quality.rawValue)
        }
        .sorted { $0.score > $1.score }
        .prefix(12)
        return Array(matched) + [Suggestion(kind: .searchQuery, title: q, subtitle: "Search the web", action: .search(q), score: 0)]
    }

    static func row(for c: BrowserCommand) -> Suggestion {
        Suggestion(kind: .command, title: c.title, subtitle: c.subtitle, action: .command(id: c.id), score: 0)
    }

    func loadZeroState() async {
        guard commandSource == nil else { return }
        zero = await engine.zeroState()
    }

    func textChanged(_ text: String, lastEditWasInsertion: Bool) {
        typed = text
        highlighted = nil
        task?.cancel()
        guard commandSource == nil else { return }
        guard !text.isEmpty else { results = nil; return }
        // Private typing stays on the Mac.
        let stream = engine.results(for: text, lastEditWasInsertion: lastEditWasInsertion, includeRemote: !isPrivate)
        task = Task { [weak self] in
            for await r in stream {
                guard !Task.isCancelled, let self, self.typed == r.query else { return }
                self.results = r
            }
        }
    }

    func moveHighlight(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { highlighted = nil; return }
        switch highlighted {
        case nil: highlighted = delta > 0 ? 0 : count - 1
        case let i?:
            let j = i + delta
            highlighted = j < 0 ? nil : min(j, count - 1)
        }
    }

    func highlight(_ i: Int?) { highlighted = i }

    /// What Return does with the field's contents.
    func submitAction(fieldText: String) -> SuggestionAction? {
        if let highlighted, rows.indices.contains(highlighted) { return rows[highlighted].action }
        // ⌘K: Return runs the best match.
        if commandSource != nil { return isTyping ? rows.first?.action : nil }
        if let inline, inline.fullText == fieldText { return .open(inline.url) }
        if let d = results?.defaultAction, fieldText == typed { return d }
        let t = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let url = URLNormalizer.urlIfNavigable(t) { return .open(url) }
        return .search(t)
    }
}

/// Cmd-T / Cmd-L / Cmd-K: a floating field over the page.
///
/// Cmd-T and Cmd-L lead with the web: suggestions, open tabs, then matching commands.
/// Cmd-K leads with Browsa: a row of tools, then commands, with a web search as the last row.
/// Typing ">" as the first character in Cmd-T or Cmd-L switches to Cmd-K.
struct CommandBar: View {
    @Environment(Browser.self) private var browser
    let mode: CommandBarMode
    @State private var model: CommandBarModel?
    @State private var fieldText = ""

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss.
            Color.black.opacity(0.18)
                .contentShape(.rect)
                .onTapGesture { close() }

            panel
                .padding(.top, 96)
                .padding(.horizontal, 40)
        }
        .task {
            let m = mode == .commands
                ? CommandBarModel(engine: browser.suggest, isPrivate: browser.currentSpace.isPrivate,
                                  commands: { [browser] in browser.availableCommands() }, featured: Self.featured)
                : CommandBarModel(engine: browser.suggest, isPrivate: browser.currentSpace.isPrivate)
            model = m
            await m.loadZeroState()
        }
    }

    /// What ⌘K suggests before you type.
    static let featured = ["panel", "tool:agents:space", "reopen", "new-space", "sidebar", "settings"]

    private var icon: String {
        switch mode {
        case .newTab: "plus.magnifyingglass"
        case .editCurrent: "magnifyingglass"
        case .commands: "command"
        }
    }

    private var placeholder: String {
        switch mode {
        case .newTab: "Search or enter address"
        case .editCurrent: "Search, enter address, or type a command"
        case .commands: "Open a tool or run a command"
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                CommandField(
                    initialText: mode == .editCurrent ? (browser.currentTab?.url?.absoluteString ?? "") : "",
                    placeholder: placeholder,
                    inline: model?.inline,
                    onChange: { text, inserted in
                        if mode != .commands, text == ">" { browser.commandBar = .commands; return }
                        fieldText = text
                        model?.textChanged(text, lastEditWasInsertion: inserted)
                    },
                    onMove: { model?.moveHighlight($0) },
                    onSubmit: { text in submit(text) },
                    onCancel: { close() })
                    .frame(height: 24)
                if browser.currentSpace.isPrivate {
                    Label("Private", systemImage: "eye.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if mode == .commands, model?.isTyping != true {
                Divider().opacity(0.6)
                ToolStrip { close() }
            }

            if let model, !model.rows.isEmpty {
                // With nothing picked, the row Return would open shows as selected, like Arc.
                // The field shows the inline completion too, so Return's target includes it.
                let shown = model.inline.map { $0.typed == fieldText ? $0.fullText : fieldText } ?? fieldText
                let target = model.highlighted ?? (model.isTyping ? model.submitAction(fieldText: shown).flatMap { a in
                    model.rows.firstIndex { $0.action == a }
                } : nil)
                Divider().opacity(0.6)
                ScrollView {
                    VStack(spacing: 2) {
                        if !model.isTyping {
                            sectionLabel(mode == .commands ? "Commands" : model.rows.first?.kind == .favorite ? "Favourites" : "Jump back in")
                        }
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            SuggestionRow(suggestion: row, highlighted: target == i,
                                          inSearch: model.isTyping, symbol: commandSymbol(row), hint: commandHint(row))
                                .onTapGesture { perform(row.action) }
                                .onHover { if $0 { model.highlight(i) } }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640)
        // Solid rather than glass: glass picks dark or light text from the page behind it, which made
        // the rows unreadable in dark mode over a white page.
        .background(PanelFill(), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    private func commandSymbol(_ row: Suggestion) -> String? {
        if case .command(let id) = row.action { return browser.symbol(forCommand: id) }
        return nil
    }

    /// The command's keys, so ⌘K teaches them.
    private func commandHint(_ row: Suggestion) -> String? {
        guard case .command(let id) = row.action else { return nil }
        if let action = ShortcutAction(rawValue: id) { return Shortcuts.shared.display(action) }
        return ["zoom-in": "⌘+", "zoom-out": "⌘−", "zoom-reset": "⌘0", "settings": "⌘,"][id]
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 4)
    }

    private func submit(_ text: String) {
        if let action = model?.submitAction(fieldText: text) {
            perform(action)
        } else if text.isEmpty, mode == .newTab {
            // Return on an empty field opens a blank tab, like Arc.
            browser.commandBar = nil
            browser.newTab(url: nil)
        }
    }

    private func perform(_ action: SuggestionAction) {
        browser.perform(action, mode: mode)
    }

    private func close() {
        browser.commandBar = nil
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool
    let inSearch: Bool
    var symbol: String?
    var hint: String?

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).lineLimit(1)
                if let sub = suggestion.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.primary.opacity(0.06), in: .capsule)
            }
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if highlighted {
                Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: suggestion.subtitle == nil ? 34 : 42)
        .background(highlighted ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
    }

    @ViewBuilder private var icon: some View {
        switch suggestion.kind {
        case .searchQuery, .searchSuggestion: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .command: Image(systemName: symbol ?? "command").foregroundStyle(.secondary)
        case .entity: Image(systemName: "book.closed").foregroundStyle(.secondary)
        case .archived: Image(systemName: "archivebox").foregroundStyle(.secondary)
        default:
            if let url = suggestion.url { FaviconView(url: url, size: 18, chip: true, letter: suggestion.title) }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
    }

    private var badge: String? {
        switch suggestion.kind {
        case .openTab: "Switch to Tab"
        case .favorite: "Favourite"
        case .archived: "Archived"
        default: nil
        }
    }
}

// MARK: - Tools

/// ⌘K's top row: every panel tool, one click to open it beside the page.
private struct ToolStrip: View {
    @Environment(Browser.self) private var browser
    let done: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(browser.library.workbench.panelTools) { tool in
                    Button {
                        done()
                        browser.showPanel(tool.id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 40, height: 40)
                                .background(.primary.opacity(browser.panel == tool.id ? 0.12 : 0.06), in: .rect(cornerRadius: 10, style: .continuous))
                            Text(tool.title).font(.caption).lineLimit(1)
                        }
                        .frame(width: 72)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(tool.summary)
                }
                Button {
                    done()
                    browser.openLibrary()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.15), style: .init(lineWidth: 1, dash: [3])))
                        Text("Get More").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 72)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Find tools and extensions in the Library")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Field

/// An NSTextField, for what SwiftUI's TextField can't do: inline completion with the tail selected,
/// and arrow keys, Return and Escape handled before the field sees them.
struct CommandField: NSViewRepresentable {
    let initialText: String
    let placeholder: String
    let inline: InlineCompletion?
    let onChange: (String, Bool) -> Void
    let onMove: (Int) -> Void
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = placeholder
        field.stringValue = initialText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.typed = initialText
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyInline(inline, to: field)
    }

    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.makeFirstResponder(self)
            // Editing the current address starts with it all selected, like Safari.
            currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField?
        /// What the user typed, without the completion.
        var typed = ""
        private var lastInline: InlineCompletion?

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let text = field.stringValue
            let inserted = text.count > typed.count && text.hasPrefix(typed)
            typed = text
            lastInline = nil
            parent?.onChange(text, inserted)
        }

        /// Shows the completion after what was typed, selected so the next key replaces it.
        func applyInline(_ inline: InlineCompletion?, to field: NSTextField) {
            guard let inline, inline != lastInline, inline.typed == typed, !inline.completion.isEmpty,
                  let editor = field.currentEditor() as? NSTextView,
                  editor.selectedRange().location == (typed as NSString).length else { return }
            lastInline = inline
            field.stringValue = inline.fullText
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (inline.completion as NSString).length))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent?.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent?.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent?.onSubmit(textView.string); return true
            case #selector(NSResponder.cancelOperation(_:)): parent?.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab accepts the inline completion.
                if textView.selectedRange().length > 0 {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                    typed = textView.string
                    parent?.onChange(typed, true)
                }
                return true
            default: return false
            }
        }
    }
}
