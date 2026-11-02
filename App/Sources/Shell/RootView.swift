import SwiftUI
import BrowserCore
import Suggest

struct RootView: View {
    @Environment(BrowserState.self) private var browser
    @Namespace private var newTabNS
    @State private var rail = TabRailController()
    @AppStorage(ReaderView.fullScreenKey) private var readerFullScreen = false
    /// Reader is between its sheet and its full-screen cover.
    @State private var readerSwapping = false

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
        // Reader in a sheet, or filling the screen. Its full-screen button swaps one for the other.
        .sheet(item: readerBinding(fullScreen: false)) { ReaderView(article: $0) }
        .fullScreenCover(item: readerBinding(fullScreen: true)) { ReaderView(article: $0) }
        .onChange(of: readerFullScreen) { swapReaderPresentation() }
        .sheet(isPresented: $browser.isDownloadsPresented) {
            DownloadsView()
        }
        // A light tap when a download lands, like Safari's downloads button bounce.
        .sensoryFeedback(.success, trigger: browser.downloads.lastFinished)
        // Page dialogs, permission requests and logins, one at a time.
        .modifier(WebPromptAlert())
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

extension RootView {
    /// The open article, for whichever presentation Reader is using.
    private func readerBinding(fullScreen: Bool) -> Binding<ReaderArticle?> {
        Binding {
            readerSwapping || readerFullScreen != fullScreen ? nil : browser.readerArticle
        } set: { article in
            // Only a real dismissal (Close, or swiping the sheet away) closes Reader.
            guard article == nil, !readerSwapping, readerFullScreen == fullScreen else { return }
            browser.readerArticle = nil
        }
    }

    /// Takes Reader down from one presentation without animation, then puts it up in the other
    /// once UIKit has finished, since it can't present while a dismissal is still running.
    private func swapReaderPresentation() {
        guard browser.readerArticle != nil else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { readerSwapping = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withTransaction(t) { readerSwapping = false }
        }
    }
}

/// Shows the selected tab's web view, or the start page when there's no tab.
struct WebContentView: View {
    @Environment(BrowserState.self) private var browser
    var topObscuredInset: CGFloat = 0
    var bottomObscuredInset: CGFloat = 0

    var body: some View {
        if let tab = browser.currentTab {
            WebViewHost(session: browser.session(for: tab), topObscuredInset: topObscuredInset,
                        bottomObscuredInset: bottomObscuredInset)
                .id(tab.id)
                // Swipe between tabs on the bottom pill slides the pages too.
                .transition(Motion.tabPush(forward: browser.lastTabSwipeForward))
                .overlay {
                    if let error = tab.loadError {
                        ErrorPage(tab: tab, error: error).transition(.opacity)
                    }
                }
                .animation(Motion.snappy, value: tab.loadError)
                // A tab that hasn't loaded yet shows its last picture, not a blank page.
                .overlay {
                    if tab.isAwaitingFirstPaint, let image = browser.thumbnails[tab.id] {
                        Color.clear
                            .overlay(alignment: .top) { Image(uiImage: image).resizable().scaledToFill() }
                            .clipped()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.snappy, value: tab.isAwaitingFirstPaint)
        } else {
            StartPage()
        }
    }
}

extension View {
    /// Runs the page's background colour out under the system's bars, like Safari, and matches the
    /// status items to it so they stay readable whatever the app's own appearance.
    func pageColoredSurroundings(_ tab: BrowserTab?, isEnabled: Bool = true, galleryIsUp: Bool = false) -> some View {
        let color = isEnabled && !galleryIsUp ? tab?.pageBackground : nil
        return self
            .background {
                if galleryIsUp {
                    Color(.systemGroupedBackground).ignoresSafeArea()
                } else if let color {
                    Color(cgColor: color).ignoresSafeArea()
                }
            }
            .toolbarColorScheme(color.map { $0.isLight ? .light : .dark }, for: .navigationBar)
    }
}

private struct PageMatchedAppearance: ViewModifier {
    let tab: BrowserTab?
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, tab?.pageBackground.map { $0.isLight ? .light : .dark } ?? system)
    }
}

extension View {
    /// For a bar behind the system's status items, which `pageColoredSurroundings` has flipped.
    /// Never put this around the web view, or a site's own dark mode would follow the page's colour.
    func pageMatchedAppearance(_ tab: BrowserTab?) -> some View { modifier(PageMatchedAppearance(tab: tab)) }
}

private extension CGColor {
    var isLight: Bool {
        var white: CGFloat = 1
        UIColor(cgColor: self).getWhite(&white, alpha: nil)
        return white > 0.5
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
