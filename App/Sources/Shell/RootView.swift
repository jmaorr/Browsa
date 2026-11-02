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
            Group {
                switch posture {
                case .unfolded: UnfoldedLayout()
                case .folded: FoldedLayout()
                }
            }
            // New pages ask for the desktop site on the inner display, mobile on the outer.
            .onChange(of: posture, initial: true) { _, p in
                browser.isUnfolded = (p == .unfolded)
                // A fold can cancel a swipe mid-gesture, which would leave the strip out.
                rail.reset()
            }
            // WebKit moves the page for the keyboard itself.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // One sheet for both layouts, so an open sheet (and its typed text) survives a fold.
        .sheet(isPresented: $browser.isNewTabSheetPresented) {
            NewTabSheet(engine: browser.suggest,
                        initialText: browser.newTabSheetEditsCurrentTab ? (browser.currentTab?.url?.absoluteString ?? "") : "",
                        morphFrom: browser.newTabSheetEditsCurrentTab ? browser.currentTab?.url : nil)
                // The sheet grows out of whichever plus button (or address pill) was tapped.
                .navigationTransition(.zoom(sourceID: browser.newTabSourceID, in: newTabNS))
        }
        .sheet(isPresented: $browser.isSettingsPresented) {
            // Settings keeps the system's control colours.
            SettingsView().tint(Color?.none)
        }
        .sheet(isPresented: $browser.isArchivePresented) {
            ArchiveView()
        }
        .sheet(item: $browser.readerArticle) { article in
            ReaderView(article: article)
        }
        .sheet(isPresented: $browser.isDownloadsPresented) {
            DownloadsView()
        }
        // A light tap when a download lands, like Safari's downloads button bounce.
        .sensoryFeedback(.success, trigger: browser.downloads.lastFinished)
        // Page dialogs, permission requests and logins, one at a time.
        .modifier(WebPromptAlert())
        // Tab grid, both postures. Above the layout so the page can grow out of its card.
        .overlay { TabGridOverlay() }
        .overlay { ToastOverlay() }
        // Tab icon strip, shared by both postures.
        .overlay(alignment: .leading) { TabRailView() }
        .coordinateSpace(.named("browserRoot"))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rail.containerHeight = $0 }
        .onChange(of: browser.currentTab?.id) { rail.currentTabChanged() }
        .onAppear { rail.browser = browser }
        .environment(rail)
        // Neutral chrome, like Safari. A space's colour only tints the sidebar's background.
        .tint(.primary)
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
                .transition(Motion.tabPush(forward: browser.lastTabSwipeForward))
                .overlay {
                    if let error = tab.loadError {
                        ErrorPage(tab: tab, error: error).transition(.opacity)
                    }
                }
                .animation(Motion.snappy, value: tab.loadError)
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
