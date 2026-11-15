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
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

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
        .pageColoredSurroundings(browser.tabGridLandingTab ?? browser.currentTab, galleryIsUp: browser.tabGridCoversPage)
        .onGeometryChange(for: CGFloat.self) { BarMetrics.topCornerInset($0) } action: { topInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
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
                BottomBar(sideMargin: 0, compactDrop: BarMetrics.compactDrop(bottomInset: bottomInset))
            }
            if !compact {
                if browser.downloads.isIndicatorVisible {
                    DownloadProgressButton().glassCircleButton().transition(.opacity)
                }
                HStack(spacing: 0) {
                    TabsButton().frame(width: 42, height: BarMetrics.capsuleHeight).contentShape(.rect)
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
        // Comes in with the page as the gallery's zoom lands (the gallery's own controls stay).
        .opacity(browser.tabGridHidesAddressBar && !galleryIsUp ? 0 : 1)
        .scaleEffect(browser.tabGridHidesAddressBar && !galleryIsUp ? 0.9 : 1, anchor: .bottom)
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
            Button {
                browser.isNewTabSheetPresented = false
                browser.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward").pageActionCell()
            }
            .disabled(!(browser.currentTab?.canGoForward ?? false))
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").pageActionCell() }
            Button {
                browser.toggleSavedForCurrentTab()
            } label: {
                Label(browser.isSaved(url) ? "Unsave" : "Save",
                      systemImage: browser.isSaved(url) ? "bookmark.fill" : "bookmark").pageActionCell()
            }
            Button {
                browser.afterClosingNewTabSheet { browser.findInPage() }
            } label: {
                Label("Find on Page", systemImage: "doc.text.magnifyingglass").pageActionCell()
            }
            PageMenu(closesNewTabSheetFirst: true, fillsCell: true)
        }
        .labelStyle(.iconOnly)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

extension View {
    /// A button in the page actions row takes its whole fifth of the row, not just its icon, so
    /// a tap anywhere in its slot lands. Only the icon was hit-testable before, and the More
    /// menu in particular needed several tries.
    func pageActionCell() -> some View {
        frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
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
