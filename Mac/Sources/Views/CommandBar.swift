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
    /// The row across the top (⌘K's tools, or ⌘T's favourites), when the arrow keys are in it: which item.
    /// nil = not in the row.
    private(set) var toolHighlighted: Int?
    /// How many items that row has (⌘K: tools plus Get More; ⌘T: favourites), set by the view.
    var toolCount = 0
    /// ⌘T shows the favourites in the row across the top, so the list doesn't repeat them.
    var favouritesInRow = false
    /// What's in the field now, with any inline completion, so the arrows start from the row
    /// Return would open (the one already shown as selected).
    var fieldText = ""

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
        return rows.isEmpty && !favouritesInRow ? zero.favorites.map {
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
        // A sum or a !bang leads here too, so Return copies the answer or goes to the site.
        let special = SuggestEngine.specialRow(for: q).map { [$0] } ?? []
        return special + Array(matched) + [Suggestion(kind: .searchQuery, title: q, subtitle: "Search the web", action: .search(q), score: 0)]
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
        fieldText = text
        highlighted = nil
        toolHighlighted = nil
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

    /// The row Return would open with nothing picked: shown selected, and where ↓ and ↑ start from.
    var implicitTarget: Int? {
        // The field shows the inline completion too, so Return's target includes it.
        let shown = inline.map { $0.typed == fieldText ? $0.fullText : fieldText } ?? fieldText
        guard isTyping, let a = submitAction(fieldText: shown) else { return nil }
        return rows.firstIndex { $0.action == a }
    }

    /// Whether the row across the top is showing, so ↓ from the field goes into it first.
    var hasToolRow: Bool { !isTyping && toolCount > 0 }

    /// ↓ and ↑. Order: field, then ⌘K's tool row (if showing), then the list. With nothing picked,
    /// they start from the row shown as selected, so the first ↓ moves off it rather than onto it.
    func moveHighlight(_ delta: Int) {
        let count = rows.count
        if toolHighlighted != nil {
            if delta > 0, count > 0 { toolHighlighted = nil; highlighted = 0 }
            else if delta < 0 { toolHighlighted = nil; highlighted = nil }
            return
        }
        switch highlighted ?? implicitTarget {
        case nil:
            if hasToolRow {
                if delta > 0 { toolHighlighted = 0 } else if count > 0 { highlighted = count - 1 }
                return
            }
            guard count > 0 else { return }
            highlighted = delta > 0 ? 0 : count - 1
        case let i?:
            let j = i + delta
            if j < 0 {
                highlighted = nil
                if hasToolRow { toolHighlighted = 0 }
            } else {
                highlighted = min(j, count - 1)
            }
        }
    }

    /// ← and → inside ⌘K's tool row. False when the arrows aren't in it, so the field moves its caret.
    func moveToolHighlight(_ delta: Int) -> Bool {
        guard let t = toolHighlighted else { return false }
        toolHighlighted = max(0, min(toolCount - 1, t + delta))
        return true
    }

    func highlight(_ i: Int?) { highlighted = i; if i != nil { toolHighlighted = nil } }

    /// Back to nothing picked, as when ⌘K switches between Search and Library.
    func resetHighlight() { highlighted = nil; toolHighlighted = nil }

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

/// Cmd-T / Cmd-L / Cmd-K: a Liquid Glass sheet over the page.
///
/// The frame is glass, tinted and pinned to the app's appearance, so the field and chips read the
/// same over any page. The results sit on a solid card inside it, so rows never take their colour
/// from the page behind (why this sheet used to be solid). The card has an even glass gutter on its
/// sides and bottom, and teaches the keys in its footer.
///
/// Cmd-T and Cmd-L lead with the web: favourites as glass chips, then open tabs and suggestions.
/// Cmd-K has two places, switched from the field or with Tab: Search (tools as chips, then
/// commands) and Library (everything you can add, with a preview of the one you're on).
/// Typing ">" as the first character in Cmd-T or Cmd-L switches to Cmd-K.
struct CommandBar: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    let mode: CommandBarMode
    @State private var model: CommandBarModel?
    @State private var fieldText = ""
    /// ⌘K only: Search or Library.
    @State private var place = CommandPlace.search
    /// The Library row the arrows are on.
    @State private var libraryIndex = 0
    /// Bumped to put the caret back in the field, after a click on the Search / Library switch.
    @State private var focusRequest = 0
    /// The sheet settles in from a touch smaller. Only the sheet: the dimming just fades, so its
    /// edges never visibly grow.
    @State private var settled = false

    enum CommandPlace: String, CaseIterable {
        case search = "Search", library = "Library"
        var symbol: String { self == .search ? "magnifyingglass" : "books.vertical" }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss.
            Color.black.opacity(scheme == .dark ? 0.3 : 0.14)
                .contentShape(.rect)
                .onTapGesture { close() }

            sheet
                .padding(.top, 96)
                .padding(.horizontal, 40)
                .scaleEffect(settled ? 1 : 0.98, anchor: .top)
        }
        .onAppear { withAnimation(Motion.snappy) { settled = true } }
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

    private var isLibrary: Bool { mode == .commands && place == .library }

    private var icon: String {
        switch mode {
        case .newTab, .editCurrent: "magnifyingglass"
        case .commands: isLibrary ? "books.vertical" : "command"
        }
    }

    private var placeholder: String {
        switch mode {
        case .newTab: "Search or enter address"
        case .editCurrent: "Search, enter address, or type a command"
        case .commands: isLibrary ? "Search the Library" : "Search tools and commands"
        }
    }

    // MARK: Sheet

    /// Light enough to feel like glass, solid enough that the page behind never decides the text colour.
    private var shellTint: Color {
        scheme == .dark ? Color(white: 0.16).opacity(0.62) : Color(white: 0.97).opacity(0.6)
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            fieldRow
            if showsChips {
                chips.padding(.top, -6).padding(.bottom, 4)
            }
            if showsCard {
                card
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        // The glass would pick light or dark content from the page behind; keep the app's.
        .environment(\.colorScheme, scheme)
        .frame(maxWidth: mode == .commands ? 680 : 640)
        .glassEffect(.regular.tint(shellTint), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(scheme == .dark ? 0.12 : 0.08)))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        .animation(Motion.snappy, value: place)
    }

    private var fieldRow: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            CommandField(
                initialText: mode == .editCurrent ? (browser.currentTab?.url?.absoluteString ?? "") : "",
                placeholder: placeholder,
                inline: isLibrary ? nil : model?.inline,
                focusRequest: focusRequest,
                onChange: { text, inserted in
                    if mode != .commands, text == ">" { browser.commandBar = .commands; return }
                    fieldText = text
                    libraryIndex = 0
                    model?.textChanged(text, lastEditWasInsertion: inserted)
                },
                onMove: { delta in
                    if isLibrary { moveLibrary(delta) } else { model?.moveHighlight(delta) }
                },
                onHorizontal: { isLibrary ? false : (model?.moveToolHighlight($0) ?? false) },
                onTab: {
                    // ⌘K: Tab switches between Search and Library. Elsewhere it's left to the field.
                    guard mode == .commands else { return false }
                    setPlace(place == .search ? .library : .search, refocus: false)
                    return true
                },
                onSubmit: { text in
                    if isLibrary { if let item = pickedLibraryItem { primary(item) } } else { submit(text) }
                },
                onCancel: { close() })
                .frame(height: 26)
            if browser.currentSpace.isPrivate {
                Label("Private", systemImage: "eye.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if mode == .commands {
                GlassTabs(selection: Binding(get: { place }, set: { setPlace($0, refocus: true) }),
                          options: CommandPlace.allCases, size: .large, title: { $0.rawValue }, symbol: { $0.symbol },
                          onGlass: true)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, mode == .commands ? 10 : 20)
        .frame(height: 60)
    }

    // MARK: Chips

    private var showsChips: Bool {
        guard model?.isTyping != true else { return false }
        switch mode {
        case .commands: return place == .search && !browser.library.workbench.panelTools.isEmpty
        case .newTab: return !browser.library.favorites.isEmpty
        case .editCurrent: return false
        }
    }

    @ViewBuilder private var chips: some View {
        if mode == .commands {
            ToolChips(highlighted: model?.toolHighlighted) { close() }
                .onAppear { model?.toolCount = browser.library.workbench.panelTools.count }
        } else {
            // Favourites up top, so they're a keystroke away even in full screen with the sidebar hidden.
            FavouriteChips(highlighted: model?.toolHighlighted) { close() }
                .onAppear {
                    model?.toolCount = browser.library.favorites.count
                    model?.favouritesInRow = true
                }
        }
    }

    // MARK: Card

    private var showsCard: Bool { isLibrary || !(model?.rows.isEmpty ?? true) }

    private var card: some View {
        VStack(spacing: 0) {
            if isLibrary {
                CommandLibraryPane(items: libraryItems, index: $libraryIndex,
                                   isOn: isOn, primaryTitle: primaryTitle, primary: primary, openInLibrary: openInLibrary)
            } else {
                results
            }
            footer
        }
        .background(PanelFill(), in: .rect(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    @ViewBuilder private var results: some View {
        if let model, !model.rows.isEmpty {
            // With nothing picked, the row Return would open shows as selected, like Arc.
            // The field shows the inline completion too, so Return's target includes it.
            let target = model.toolHighlighted != nil ? nil : (model.highlighted ?? model.implicitTarget)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        if !model.isTyping {
                            sectionLabel(mode == .commands ? "Suggested" : model.rows.first?.kind == .favorite ? "Favourites" : "Jump back in")
                        }
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            SuggestionRow(suggestion: row, highlighted: target == i,
                                          inSearch: model.isTyping, symbol: commandSymbol(row), hint: commandHint(row))
                                .id(i)
                                .onTapGesture { perform(row.action) }
                                .onHover { if $0 { model.highlight(i) } }
                        }
                    }
                    .padding(6)
                }
                // The arrow keys keep the picked row in view.
                .onChange(of: model.highlighted) { _, i in if let i { proxy.scrollTo(i) } }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The keys for what's on screen, inside the card.
    private var footer: some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: 6) {
                    KeyCap(hint.key)
                    Text(hint.label)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private struct KeyHint: Hashable {
        let key: String
        let label: String
        init(_ key: String, _ label: String) { self.key = key; self.label = label }
    }

    private var hints: [KeyHint] {
        if isLibrary {
            return [KeyHint("↵", pickedLibraryItem.map(primaryTitle) ?? "Add"), KeyHint("⇥", "Search"), KeyHint("esc", "Close")]
        }
        switch mode {
        case .commands: return [KeyHint("↵", "Run"), KeyHint("⇥", "Library"), KeyHint("esc", "Close")]
        case .newTab, .editCurrent:
            let third = model?.inline != nil ? KeyHint("⇥", "Complete") : KeyHint(">", "Commands")
            return [KeyHint("↵", "Open"), third, KeyHint("esc", "Close")]
        }
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
            .padding(.bottom, 2)
    }

    // MARK: Search / Library

    private func setPlace(_ new: CommandPlace, refocus: Bool) {
        guard new != place else { return }
        place = new
        libraryIndex = 0
        model?.resetHighlight()
        if refocus { focusRequest += 1 }
    }

    private var libraryItems: [CommandLibraryItem] {
        CommandLibraryItem.all(matching: fieldText)
    }

    private var pickedLibraryItem: CommandLibraryItem? {
        let items = libraryItems
        return items.isEmpty ? nil : items[min(libraryIndex, items.count - 1)]
    }

    private func moveLibrary(_ delta: Int) {
        let count = libraryItems.count
        guard count > 0 else { return }
        libraryIndex = max(0, min(count - 1, libraryIndex + delta))
    }

    private func isOn(_ item: CommandLibraryItem) -> Bool {
        switch item.kind {
        case .pack: LibraryCatalog.pack(item.id).map { LibraryActions.isPackOn($0, in: browser) } ?? false
        case .plugin: LibraryActions.isOn(item.id, in: browser)
        case .verified: browser.library.extensionCatalog.items.contains { $0.source.key.lowercased().contains(item.id.lowercased()) }
        }
    }

    private func primaryTitle(_ item: CommandLibraryItem) -> String {
        switch item.kind {
        case .pack, .plugin: isOn(item) ? "Turn Off" : "Add"
        case .verified: isOn(item) ? "Show in Library" : "Add"
        }
    }

    /// Return, or the preview's main button: packs and tools switch on and off right here; an
    /// extension goes to the Library, which asks before adding it.
    private func primary(_ item: CommandLibraryItem) {
        let on = isOn(item)
        switch item.kind {
        case .pack:
            if let pack = LibraryCatalog.pack(item.id) { LibraryActions.togglePack(pack, on: !on, in: browser) }
        case .plugin:
            LibraryActions.set(item.id, on: !on, in: browser)
        case .verified:
            close()
            browser.openLibrary(on ? nil : "add:" + item.id)
        }
    }

    private func openInLibrary(_ item: CommandLibraryItem) {
        close()
        browser.openLibrary(item.kind == .verified ? nil : item.id)
    }

    // MARK: Actions

    private func submit(_ text: String) {
        if let t = model?.toolHighlighted, mode == .newTab {
            let favourites = browser.library.sortedFavorites
            close()
            if favourites.indices.contains(t) { browser.open(favourites[t]) }
            return
        }
        if let t = model?.toolHighlighted {
            let tools = browser.library.workbench.panelTools
            close()
            if tools.indices.contains(t) { browser.showPanel(tools[t].id) }
            return
        }
        if let action = model?.submitAction(fieldText: text) {
            perform(action)
        } else if text.isEmpty, mode == .newTab {
            // Return on an empty field opens a blank tab, like Arc.
            browser.commandBar = nil
            browser.newTab(url: nil, asNewTab: true)
        }
    }

    private func perform(_ action: SuggestionAction) {
        browser.perform(action, mode: mode)
    }

    private func close() {
        browser.commandBar = nil
    }
}

/// The grey behind the row the arrows are on. A fixed grey rather than a vibrant primary tint,
/// which all but disappeared on the card inside the glass.
enum RowHighlight {
    static func color(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.085) }
}

/// A key, drawn as a small cap.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 18)
            .background(.primary.opacity(0.07), in: .rect(cornerRadius: 5, style: .continuous))
    }
}

private struct SuggestionRow: View {
    @Environment(\.colorScheme) private var scheme
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
                KeyCap(hint)
            }
            if highlighted {
                KeyCap("↵")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: suggestion.subtitle == nil ? 34 : 42)
        .background(highlighted ? RowHighlight.color(scheme) : .clear,
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

// MARK: - Chips

/// A row of glass capsules under the field: ⌘K's tools, ⌘T's favourites. Scrolls sideways when
/// there are more than fit, keeping the one the arrows are on in view.
private struct ChipRow<Content: View>: View {
    var highlighted: Int?
    let content: Content

    init(highlighted: Int?, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // No glass container: it merged neighbouring chips' glass and drew a second outline
                // around a raised one. Room above and below so the lift's shadow isn't cut off.
                HStack(spacing: 8) { content }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .onChange(of: highlighted) { _, i in if let i { withAnimation(Motion.snappy) { proxy.scrollTo(i) } } }
        }
    }
}

/// One capsule: an icon in a small circle, then a name. Glass at rest; under the pointer or the
/// arrow keys it turns solid white (black in dark mode) and lifts off the sheet.
private struct GlassChip<Icon: View>: View {
    let title: String
    var highlighted = false
    let icon: Icon
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var raised: Bool { highlighted || hovering }

    init(title: String, highlighted: Bool, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) {
        self.title = title
        self.highlighted = highlighted
        self.icon = icon()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon.frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 13)
            .frame(height: 34)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // One shape per chip. Glass here sat on the sheet's own glass and, with an outline on top,
        // read as a box in a box. At rest a soft sunken fill; raised, solid with a shadow.
        .background {
            if raised {
                Capsule()
                    .fill(RaisedFill.color(scheme))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 6, y: 2)
            } else {
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05))
            }
        }
        .animation(Motion.quick, value: raised)
        .onHover { hovering = $0 }
    }
}

/// ⌘K's chips: every panel tool, one click to open it beside the page.
private struct ToolChips: View {
    @Environment(Browser.self) private var browser
    var highlighted: Int?
    let done: () -> Void

    var body: some View {
        ChipRow(highlighted: highlighted) {
            ForEach(Array(browser.library.workbench.panelTools.enumerated()), id: \.element.id) { i, tool in
                let tint = LibraryCatalog.plugin(tool.id)?.tint ?? .secondary
                GlassChip(title: tool.title, highlighted: highlighted == i) {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.2), in: .circle)
                } action: {
                    done()
                    browser.showPanel(tool.id)
                }
                .help(tool.summary)
                .id(i)
            }
        }
    }
}

/// ⌘T's chips: your favourites, one click (or arrows and Return) to open one.
private struct FavouriteChips: View {
    @Environment(Browser.self) private var browser
    var highlighted: Int?
    let done: () -> Void

    var body: some View {
        ChipRow(highlighted: highlighted) {
            ForEach(Array(browser.library.sortedFavorites.enumerated()), id: \.element.id) { i, favorite in
                GlassChip(title: favorite.displayName, highlighted: highlighted == i) {
                    FaviconView(url: favorite.url, size: 18, chip: true, letter: favorite.customName ?? favorite.title)
                } action: {
                    done()
                    browser.open(favorite)
                }
                .help(favorite.displayName)
                .id(i)
            }
        }
    }
}

// MARK: - Library

/// One thing ⌘K's Library can show: a pack, a Browsa tool, or a verified extension.
struct CommandLibraryItem: Identifiable {
    enum Kind { case pack, plugin, verified }

    let id: String
    let kind: Kind
    let title: String
    let blurb: String
    let about: String
    let symbol: String
    let tint: Color
    var icon: NSImage?

    var section: String {
        switch kind {
        case .pack: "Packs"
        case .plugin: "Tools"
        case .verified: "Extensions"
        }
    }

    var kindLabel: String {
        switch kind {
        case .pack: "Pack"
        case .plugin: "Tool"
        case .verified: "Verified extension"
        }
    }

    /// Packs, then tools, then verified extensions, matching what's typed.
    @MainActor static func all(matching query: String) -> [CommandLibraryItem] {
        let packs = LibraryCatalog.packs.map {
            CommandLibraryItem(id: $0.id, kind: .pack, title: $0.title, blurb: $0.blurb, about: $0.about,
                               symbol: $0.id == LibraryCatalog.agentPack.id ? AgentIdentity.symbol : "hand.raised.fill",
                               tint: $0.id == LibraryCatalog.agentPack.id ? .orange : .blue)
        }
        let tools = LibraryCatalog.toolPlugins.map {
            CommandLibraryItem(id: $0.id, kind: .plugin, title: $0.title, blurb: $0.blurb, about: $0.about,
                               symbol: $0.symbol, tint: $0.tint)
        }
        let extensions = LibraryCatalog.verified.map {
            CommandLibraryItem(id: $0.id, kind: .verified, title: $0.name, blurb: $0.blurb, about: "",
                               symbol: "puzzlepiece.extension.fill", tint: $0.color, icon: $0.icon)
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let everything = packs + tools + extensions
        guard !q.isEmpty else { return everything }
        return everything.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.blurb.localizedCaseInsensitiveContains(q) }
    }
}

/// ⌘K's Library place: the list on the left, a preview of the picked one on the right.
private struct CommandLibraryPane: View {
    @Environment(\.colorScheme) private var scheme
    let items: [CommandLibraryItem]
    @Binding var index: Int
    let isOn: (CommandLibraryItem) -> Bool
    let primaryTitle: (CommandLibraryItem) -> String
    let primary: (CommandLibraryItem) -> Void
    let openInLibrary: (CommandLibraryItem) -> Void

    var body: some View {
        if items.isEmpty {
            Text("Nothing in the Library matches.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            let picked = items[min(index, items.count - 1)]
            HStack(spacing: 0) {
                list
                    .frame(width: 290)
                Divider().opacity(0.6)
                preview(picked)
            }
            .frame(height: 380)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i == 0 || items[i - 1].section != item.section {
                            Text(item.section)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, i == 0 ? 4 : 10)
                                .padding(.bottom, 3)
                        }
                        row(item, highlighted: i == min(index, items.count - 1))
                            .id(item.id)
                            .onTapGesture { index = i }
                            .onHover { if $0 { index = i } }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: index) { _, i in if items.indices.contains(i) { proxy.scrollTo(items[i].id) } }
        }
    }

    private func row(_ item: CommandLibraryItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(isOn(item) ? "\(item.kindLabel) · Added" : item.kindLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        // Grey, like every other list in the sheet.
        .background(highlighted ? RowHighlight.color(scheme) : .clear,
                    in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }

    private func preview(_ item: CommandLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if LibraryArt.has(item.id) {
                    LibraryArtView(id: item.id)
                } else {
                    ZStack {
                        item.tint.opacity(0.18)
                        ItemIcon(item: item, size: 56)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .id(item.id)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold))
                Text(isOn(item) ? "\(item.kindLabel) · Added" : item.kindLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(item.about.isEmpty ? item.blurb : item.about)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(primaryTitle(item)) { primary(item) }
                    .buttonStyle(.glassProminent)
                Button("Open in Library") { openInLibrary(item) }
                    .buttonStyle(.glass)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A Library item's icon: an extension's store icon, or the symbol on its tint.
private struct ItemIcon: View {
    let item: CommandLibraryItem
    let size: CGFloat

    var body: some View {
        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.25, style: .continuous))
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(item.tint, in: .rect(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

// MARK: - Field

/// An NSTextField, for what SwiftUI's TextField can't do: inline completion with the tail selected,
/// and arrow keys, Return and Escape handled before the field sees them.
struct CommandField: NSViewRepresentable {
    let initialText: String
    let placeholder: String
    let inline: InlineCompletion?
    /// Bump it to put the caret back in the field, at the end (after a click elsewhere in the sheet).
    var focusRequest = 0
    let onChange: (String, Bool) -> Void
    let onMove: (Int) -> Void
    /// ← and →: true when handled (⌘K's tool row), false to leave them to the field.
    var onHorizontal: (Int) -> Bool = { _ in false }
    /// Tab: true when handled (⌘K switching Search and Library). Otherwise Tab accepts the inline completion.
    var onTab: () -> Bool = { false }
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.placeholderString = placeholder
        field.stringValue = initialText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.typed = initialText
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        // ⌘K's Search and Library each have their own placeholder.
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        context.coordinator.applyInline(inline, to: field)
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
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
        var focusRequest = 0
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
            case #selector(NSResponder.moveLeft(_:)): return parent?.onHorizontal(-1) ?? false
            case #selector(NSResponder.moveRight(_:)): return parent?.onHorizontal(1) ?? false
            case #selector(NSResponder.insertNewline(_:)): parent?.onSubmit(textView.string); return true
            case #selector(NSResponder.cancelOperation(_:)): parent?.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)):
                if parent?.onTab() == true { return true }
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
