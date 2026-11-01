import SwiftUI
import BrowserCore
import Suggest

/// Inner display: Arc-style collapsible sidebar + full-bleed web content.
/// Sidebar toggle and the one-tap plus live in the Duo's system vertical bar (landscape), or at the
/// leading edge of the top toolbar (portrait, where the system uses horizontal bars).
struct UnfoldedLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.toolbarVerticalEdge) private var verticalBarEdge

    /// Put the sidebar on the edge opposite the system vertical bar so they never stack.
    private var sidebarEdge: HorizontalEdge { verticalBarEdge == .leading ? .trailing : .leading }

    var body: some View {
        let space = browser.currentSpace
        NavigationStack {
            HStack(spacing: 0) {
                if sidebarEdge == .leading, space.isSidebarOpen { sidebar(edge: .leading) }
                WebContentView()
                    .clipShape(.rect(cornerRadius: space.isSidebarOpen ? 12 : 0, style: .continuous))
                    .padding(space.isSidebarOpen ? 6 : 0)
                if sidebarEdge == .trailing, space.isSidebarOpen { sidebar(edge: .trailing) }
            }
            .background(SpacePalette.color(space.colorIndex).opacity(0.12))
            .animation(.smooth(duration: 0.3), value: space.isSidebarOpen)
            .toolbar { toolbar }
            .toolbarTitleDisplayMode(.inline)
            .navigationTitle(browser.currentTab?.displayTitle ?? "")
            .duoVerticalBarPrefersOurItems()
        }
        .background {
            // Hardware keyboard: Cmd-S toggles the sidebar, like Arc.
            Button("") { toggleSidebar() }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private func sidebar(edge: Edge) -> some View {
        SidebarView()
            .frame(width: 280)
            .transition(.move(edge: edge).combined(with: .opacity))
    }

    private func toggleSidebar() {
        browser.currentSpace.isSidebarOpen.toggle()
        browser.scheduleSave()
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Toggle Sidebar", systemImage: "sidebar.leading") { toggleSidebar() }
                .sensoryFeedback(.selection, trigger: browser.currentSpace.isSidebarOpen)
        }
        .duoPinnedToVerticalBar()

        ToolbarItem(placement: .topBarLeading) {
            Button("New Tab", systemImage: "plus") { browser.presentNewTab() }
        }
        .duoPinnedToVerticalBar()

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let tab = browser.currentTab {
                Button("Back", systemImage: "chevron.backward") { browser.session(for: tab).webView.goBack() }
                    .disabled(!tab.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { browser.session(for: tab).webView.goForward() }
                    .disabled(!tab.canGoForward)
                if let url = tab.url {
                    FavoriteToggle(url: url, title: tab.displayTitle)
                    ShareLink(item: url)
                }
            }
        }
    }
}

struct FavoriteToggle: View {
    @Environment(BrowserState.self) private var browser
    let url: URL
    let title: String

    var body: some View {
        let isFav = browser.isFavorite(url)
        Button(isFav ? "Remove Favourite" : "Add Favourite", systemImage: isFav ? "star.fill" : "star") {
            if isFav, let fav = browser.favorites.first(where: { URLNormalizer.key(for: $0.url) == URLNormalizer.key(for: url) }) {
                browser.removeFavorite(fav)
            } else {
                browser.addFavorite(url: url, title: title)
            }
        }
        .sensoryFeedback(.success, trigger: isFav)
    }
}
