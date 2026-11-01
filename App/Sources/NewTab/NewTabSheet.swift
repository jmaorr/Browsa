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

    init(engine: SuggestEngine, initialText: String) {
        _model = State(initialValue: NewTabModel(engine: engine))
        self.initialText = initialText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FavoritesGrid(favorites: browser.favorites.sorted { $0.order < $1.order },
                                  compact: model.isTyping,
                                  onOpen: { browser.perform(.open($0.url), source: .bookmark) },
                                  onRename: { renameText = $0.displayName; editingFavorite = $0 },
                                  onRemove: { browser.removeFavorite($0) })
                    if model.isTyping {
                        SuggestionList(results: model.results) { browser.perform($0) }
                    } else if let zero = model.zero {
                        ZeroStateSections(zero: zero) { browser.perform($0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task { await model.loadZeroState() }
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
            AddressField(initialText: initialText, inline: model.inline,
                         placeholder: "Search or enter address",
                         onTextChange: { model.textChanged($0, lastEditWasInsertion: $1) },
                         onSubmit: { text in
                             if let action = model.submitAction(fieldText: text) { browser.perform(action) }
                         })
                .frame(height: 44)
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
                    ForEach(favorites.prefix(12)) { tile($0, size: 52) }
                }
            }
            .transition(.opacity)
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
    var onAction: (SuggestionAction) -> Void

    var body: some View {
        if !zero.topSites.isEmpty {
            section("Frequently visited") {
                ForEach(zero.topSites) { s in SuggestionRow(suggestion: s) { onAction(s.action) } }
            }
        }
        if !zero.recentTabs.isEmpty {
            section("Recent tabs") {
                ForEach(zero.recentTabs, id: \.id) { t in
                    let s = Suggestion(kind: .openTab, title: t.title, subtitle: URLNormalizer.displayHost(t.url),
                                       action: .switchToTab(id: t.id, url: t.url), score: 0)
                    SuggestionRow(suggestion: s) { onAction(s.action) }
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
    var onAction: (SuggestionAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let results {
                ForEach(results.local) { s in SuggestionRow(suggestion: s) { onAction(s.action) } }
                if let p = results.primary { SuggestionRow(suggestion: p) { onAction(p.action) } }
                ForEach(results.remote) { s in SuggestionRow(suggestion: s) { onAction(s.action) } }
            }
        }
        // Remote rows append below; animate only insertions so nothing on screen jumps.
        .animation(.snappy(duration: 0.15), value: results?.remote.count)
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var icon: some View {
        switch suggestion.kind {
        case .searchSuggestion, .searchQuery where suggestion.url == nil:
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .openTab:
            Image(systemName: "square.on.square").foregroundStyle(.secondary)
        default:
            if let url = suggestion.url { FaviconView(url: url, size: 24) }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
    }
}
