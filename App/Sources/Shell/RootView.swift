import SwiftUI
import BrowserCore
import Suggest

struct RootView: View {
    @Environment(BrowserState.self) private var browser
    @Namespace private var newTabNS
    @State private var rail = TabRailController()

    var body: some View {
        @Bindable var browser = browser
        PostureReader { posture in
            switch posture {
            case .unfolded: UnfoldedLayout()
            case .folded: FoldedLayout()
            }
        }
        // One sheet for both layouts, so an open sheet (and its typed text) survives a fold.
        .sheet(isPresented: $browser.isNewTabSheetPresented) {
            NewTabSheet(engine: browser.suggest,
                        initialText: browser.newTabSheetEditsCurrentTab ? (browser.currentTab?.url?.absoluteString ?? "") : "")
                // The sheet grows out of whichever plus button (or address pill) was tapped.
                .navigationTransition(.zoom(sourceID: browser.newTabSourceID, in: newTabNS))
        }
        .sheet(isPresented: $browser.isTabSwitcherPresented) {
            TabSwitcherSheet()
        }
        .sheet(isPresented: $browser.isSettingsPresented) {
            SettingsView()
        }
        // Tab icon strip, shared by both postures.
        .overlay(alignment: .leading) { TabRailView() }
        .coordinateSpace(.named("browserRoot"))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rail.containerHeight = $0 }
        .onChange(of: browser.currentTab?.id) { rail.currentTabChanged() }
        .onAppear { rail.browser = browser }
        .environment(rail)
        .tint(SpacePalette.color(browser.currentSpace.colorIndex))
        .environment(\.newTabNamespace, newTabNS)
    }
}

/// Shows the selected tab's web view, or the start page when there's no tab.
struct WebContentView: View {
    @Environment(BrowserState.self) private var browser
    var bottomObscuredInset: CGFloat = 0

    var body: some View {
        if let tab = browser.currentTab {
            WebViewHost(session: browser.session(for: tab), bottomObscuredInset: bottomObscuredInset)
                .id(tab.id)
                // Swipe between tabs on the bottom pill slides the pages too.
                .transition(browser.lastTabSwipeForward.map { fwd in
                    AnyTransition.push(from: fwd ? .trailing : .leading)
                } ?? .opacity)
                .overlay(alignment: .top) {
                    if tab.isLoading {
                        ProgressView(value: tab.estimatedProgress)
                            .progressViewStyle(.linear)
                            .transition(.opacity)
                    }
                }
        } else {
            StartPage()
        }
    }
}

/// Empty state: big plus, plus favourites for one-tap access.
struct StartPage: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            FavoritesGrid(favorites: browser.favorites.sorted { $0.order < $1.order }, compact: false,
                          onOpen: { browser.perform(.open($0.url), source: .bookmark) },
                          onRename: { _ in }, onRemove: { browser.removeFavorite($0) })
                .frame(maxWidth: 420)
            Button { browser.presentNewTab(from: NewTabSource.startPage.rawValue) } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.glass)
            .newTabZoomSource(.startPage)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

enum SpacePalette {
    static let colors: [Color] = [.indigo, .orange, .teal, .pink, .green, .purple]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}
