import SwiftUI
import BrowserCore
import Suggest

/// A phone with no vertical bar beside the page. Everything lives in one bar at the bottom, in
/// thumb reach, and the page has the rest of the screen.
///
/// - Bar: back, the address capsule, tabs, then plus on the outside.
/// - Scrolling down shrinks the capsule and hides the buttons, as on the outer display.
/// - The rest of the page's controls are in the address sheet, behind the capsule.
struct PhoneLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @State private var topInset: CGFloat = 0

    private var compact: Bool { browser.currentTab?.isChromeCompact ?? false }

    var body: some View {
        ZStack {
            WebContentView(topObscuredInset: topInset, bottomObscuredInset: BarMetrics.underCapsuleInset)
                .ignoresSafeArea(.all, edges: .vertical)
            TabGridOverlay()
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .bottom) { bar }
        }
        .pageColoredSurroundings(browser.currentTab, galleryIsUp: browser.tabGridCoversPage)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .onAppear {
            rail.sidebarShowsTabs = false
            rail.edge = .trailing
            rail.isBesideVerticalBar = false
        }
    }

    private var bar: some View {
        let galleryIsUp = browser.isTabSwitcherPresented
        return HStack(spacing: 8) {
            if !compact, !galleryIsUp {
                HistoryButton(forward: false).glassCircleButton().transition(.opacity)
            }
            if galleryIsUp {
                // The gallery's own capsule, the space switcher, sits here.
                Spacer(minLength: 0)
            } else {
                BottomBar(sideMargin: 0)
            }
            if !compact {
                if browser.downloads.isIndicatorVisible {
                    DownloadProgressButton().glassCircleButton().transition(.opacity)
                }
                HStack(spacing: 0) {
                    TabsButton(scrubsTabRail: true).frame(width: 42, height: BarMetrics.capsuleHeight).contentShape(.rect)
                    NewTabButton().frame(width: 42, height: BarMetrics.capsuleHeight).contentShape(.rect)
                }
                .labelStyle(.iconOnly)
                .fontWeight(.medium)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: BarMetrics.floatingBarMaxWidth)
        .padding(.horizontal, 16)
        .animation(Motion.collapse, value: compact)
        .hiddenWhileKeyboardIsUp()
    }
}

/// The page's controls in the address sheet, for a layout with no room for them on the bar.
struct PageActionsRow: View {
    @Environment(BrowserState.self) private var browser
    let url: URL

    var body: some View {
        HStack(spacing: 0) {
            Button("Forward", systemImage: "chevron.forward") {
                browser.isNewTabSheetPresented = false
                browser.goForward()
            }
            .disabled(!(browser.currentTab?.canGoForward ?? false))
            .frame(maxWidth: .infinity)
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                .frame(maxWidth: .infinity)
            Button(browser.isSaved(url) ? "Unsave" : "Save",
                   systemImage: browser.isSaved(url) ? "bookmark.fill" : "bookmark") {
                browser.toggleSavedForCurrentTab()
            }
            .frame(maxWidth: .infinity)
            Button("Find on Page", systemImage: "doc.text.magnifyingglass") {
                browser.afterClosingNewTabSheet { browser.findInPage() }
            }
            .frame(maxWidth: .infinity)
            PageMenu(closesNewTabSheetFirst: true)
                .frame(maxWidth: .infinity)
        }
        .labelStyle(.iconOnly)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

extension BrowserState {
    /// UIKit can't present another sheet until this one has gone.
    func afterClosingNewTabSheet(_ action: @escaping @MainActor () -> Void) {
        guard isNewTabSheetPresented else { return action() }
        isNewTabSheetPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }
}
