import SwiftUI
import BrowserCore
import Suggest

/// The sheet behind every plus button. Keyboard is up immediately. Before typing: favourites grid,
/// top sites and recent tabs. While typing: favourites shrink to one row and suggestions take over.
struct NewTabSheet: View {
    @Environment(BrowserState.self) private var browser
    @State private var model: NewTabModel
    @State private var editingFavorite: Favorite?
    @State private var renameText = ""
    private let initialText: String
    /// When editing the current page: the URL whose short host label (as shown in the pill)
    /// slides over into the field and becomes the full, selected address.
    private let morphFrom: URL?
    @State private var morphed = false

    init(engine: SuggestEngine, initialText: String, morphFrom: URL? = nil) {
        _model = State(initialValue: NewTabModel(engine: engine))
        self.initialText = initialText
        self.morphFrom = morphFrom
        _morphed = State(initialValue: morphFrom == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        FavoritesGrid(favorites: browser.favorites.sorted { $0.order < $1.order },
                                      compact: model.isTyping,
                                      onOpen: { browser.perform(.open($0.url), source: .bookmark) },
                                      onRename: { renameText = $0.displayName; editingFavorite = $0 },
                                      onRemove: { browser.removeFavorite($0) })
                        if model.isTyping {
                            SuggestionList(results: model.results, highlightedID: model.highlightedSuggestion?.id) {
                                browser.perform($0)
                            }
                        } else if let zero = model.zero {
                            ZeroStateSections(zero: zero, highlightedID: model.highlightedSuggestion?.id) {
                                browser.perform($0)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(Motion.snappy, value: model.isTyping)
                }
                .scrollDismissesKeyboard(.interactively)
                // Keep the arrow-key highlight on screen without jumping when it already is.
                .onChange(of: model.highlightedSuggestion?.id) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.snappy) { proxy.scrollTo(id) }
                }
            }
        }
        .task { await model.loadZeroState() }
        .task {
            guard !morphed else { return }
            // Let the zoom get underway first, so the slide reads as part of it.
            if !Motion.reduced { try? await Task.sleep(for: .milliseconds(160)) }
            withAnimation(Motion.spring) { morphed = true }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert("Rename favourite", isPresented: .init(get: { editingFavorite != nil },
                                                    set: { if !$0 { editingFavorite = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let f = editingFavorite { browser.renameFavorite(f, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .opacity(morphed ? 1 : 0)
                .scaleEffect(morphed || Motion.reduced ? 1 : 0.6)
            AddressField(initialText: initialText, inline: model.inline,
                         placeholder: "Search, address or command",
                         onTextChange: { model.textChanged($0, lastEditWasInsertion: $1) },
                         onSubmit: { text in
                             if let action = model.submitAction(fieldText: text) { browser.perform(action) }
                         },
                         onMoveHighlight: { model.moveHighlight($0) },
                         onEscape: {
                             // First Esc leaves the list, second closes the sheet (like Spotlight).
                             if model.highlighted != nil { model.clearHighlight() }
                             else { browser.isNewTabSheetPresented = false }
                         })
                .frame(height: 44)
                // The field fades in under the host label as it slides left.
                .opacity(morphed ? 1 : 0)
                .overlay {
                    if let url = morphFrom {
                        HStack(spacing: 8) {
                            FaviconView(url: url, size: 18)
                            Text(URLNormalizer.displayHost(url)).font(.callout).lineLimit(1)
                        }
                        // Starts centred like the pill it zoomed out of, then glides to the
                        // field's leading edge while the full URL takes its place.
                        .frame(maxWidth: .infinity, alignment: morphed ? .leading : .center)
                        .opacity(morphed ? 0 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            Button("Cancel") { browser.isNewTabSheetPresented = false }
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - Favourites

struct FavoritesGrid: View {
    let favorites: [Favorite]
    /// One horizontal row while the user is typing; full grid otherwise.
    let compact: Bool
    var onOpen: (Favorite) -> Void
    var onRename: (Favorite) -> Void
    var onRemove: (Favorite) -> Void

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 88), spacing: 12)]
    /// Tiles pop in one after another the first time the sheet opens.
    @State private var appeared = false

    var body: some View {
        if favorites.isEmpty {
            EmptyView()
        } else if compact {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { ForEach(favorites) { tile($0, size: 36) } }
            }
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Favourites").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(favorites.prefix(12).enumerated()), id: \.element.id) { i, fav in
                        tile(fav, size: 52)
                            .scaleEffect(appeared || Motion.reduced ? 1 : 0.82)
                            .opacity(appeared ? 1 : 0)
                            // ~25 ms apart: reads as a ripple, done before the keyboard lands.
                            .animation(Motion.bouncy.delay(Double(i) * 0.025), value: appeared)
                    }
                }
            }
            .transition(.opacity)
            .onAppear { appeared = true }
        }
    }

    private func tile(_ fav: Favorite, size: CGFloat) -> some View {
        Button { onOpen(fav) } label: {
            VStack(spacing: 6) {
                FaviconView(url: fav.url, size: size)
                if !compact {
                    Text(fav.displayName).font(.caption2).lineLimit(1).foregroundStyle(.primary)
                }
            }
            .frame(minWidth: size)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") { onRename(fav) }
            Button("Remove", systemImage: "star.slash", role: .destructive) { onRemove(fav) }
        }
        .accessibilityLabel(fav.displayName)
    }
}

// MARK: - Zero state

struct ZeroStateSections: View {
    let zero: ZeroState
    var highlightedID: String? = nil
    var onAction: (SuggestionAction) -> Void

    var body: some View {
        if !zero.topSites.isEmpty {
            section("Frequently visited") {
                ForEach(zero.topSites) { s in
                    SuggestionRow(suggestion: s, highlighted: s.id == highlightedID) { onAction(s.action) }
                }
            }
        }
        if !zero.recentTabs.isEmpty {
            section("Recent tabs") {
                ForEach(zero.recentTabs.map(NewTabModel.row(for:))) { s in
                    SuggestionRow(suggestion: s, highlighted: s.id == highlightedID) { onAction(s.action) }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Suggestions

struct SuggestionList: View {
    let results: SuggestResults?
    var highlightedID: String? = nil
    var onAction: (SuggestionAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let results {
                ForEach(results.local) { row($0) }
                if let p = results.primary { row(p) }
                ForEach(results.remote) { row($0) }
            }
        }
        // Remote rows append below; animate only insertions so nothing on screen jumps.
        .animation(.snappy(duration: 0.15), value: results?.remote.count)
    }

    private func row(_ s: Suggestion) -> some View {
        SuggestionRow(suggestion: s, highlighted: s.id == highlightedID) { onAction(s.action) }
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    var highlighted = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title).lineLimit(1).foregroundStyle(.primary)
                    if let sub = suggestion.subtitle {
                        Text(sub).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if suggestion.kind == .favorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background {
                // Arrow-key highlight: a tinted rounded rect, like Spotlight.
                if highlighted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.tint.opacity(0.16))
                }
            }
            .contentShape(.rect(cornerRadius: 10))
            .padding(.horizontal, -8)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)   // trackpad / pointer
        .id(suggestion.id)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private var accessibilityText: String {
        let what: String
        switch suggestion.kind {
        case .openTab: what = "Switch to tab"
        case .command: what = "Command"
        case .archived: what = "Archived tab"
        case .favorite: what = "Favourite"
        case .searchSuggestion, .searchQuery: what = suggestion.url == nil ? "Search" : "Open"
        default: what = "Open"
        }
        return [what, suggestion.title, suggestion.subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private var icon: some View {
        switch suggestion.kind {
        case .searchSuggestion, .searchQuery where suggestion.url == nil:
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .openTab:
            Image(systemName: "square.on.square").foregroundStyle(.secondary)
        case .command:
            Image(systemName: "command").foregroundStyle(.tint)
        case .archived:
            Image(systemName: "archivebox").foregroundStyle(.secondary)
        default:
            if let url = suggestion.url { FaviconView(url: url, size: 24) }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
    }
}
