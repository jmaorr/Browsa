import SwiftUI
import WebKit
import BrowserCore
import Suggest

/// Back and forward that work like Safari's: tap to go one step, press and hold for the
/// page's history. `Menu(primaryAction:)` gives exactly that with the system's own menu.
struct HistoryButton: View {
    @Environment(BrowserState.self) private var browser
    let forward: Bool

    var body: some View {
        let tab = browser.currentTab
        let enabled = forward ? (tab?.canGoForward ?? false) : (tab?.canGoBack ?? false)
        Menu {
            if let tab {
                let wv = browser.session(for: tab).webView
                // Nearest first, like Safari's list.
                let items = forward ? wv.backForwardList.forwardList : wv.backForwardList.backList.reversed()
                ForEach(Array(items.prefix(15).enumerated()), id: \.offset) { _, item in
                    Button {
                        wv.go(to: item)
                    } label: {
                        Text(item.title?.isEmpty == false ? item.title! : URLNormalizer.displayHost(item.url))
                        Text(URLNormalizer.displayHost(item.url))
                    }
                }
            }
        } label: {
            Label(forward ? "Forward" : "Back", systemImage: forward ? "chevron.forward" : "chevron.backward")
        } primaryAction: {
            forward ? browser.goForward() : browser.goBack()
        }
        .disabled(!enabled)
        .sensoryFeedback(.selection, trigger: tab?.url)
    }
}

/// Safari-style tab button: the number of open tabs in a rounded square.
struct TabsButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let count = browser.currentSpace.allTabs.count
        Button { browser.isTabSwitcherPresented = true } label: {
            Text(count > 99 ? "∞" : "\(count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.8))
                .animation(Motion.snappy, value: count)
        }
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(count) open")
    }
}

/// Everything else about the page, in one native menu.
struct PageMenu: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let tab = browser.currentTab
        Menu {
            if let tab, let url = tab.url {
                Section {
                    Button("Copy Link", systemImage: "link") {
                        browser.copyToPasteboard(url); browser.showToast("Link copied")
                    }
                    ShareLink(item: url)
                }
                Section {
                    Button(browser.isFavorite(url) ? "Remove from Favourites" : "Add to Favourites",
                           systemImage: browser.isFavorite(url) ? "star.slash" : "star") {
                        browser.toggleFavoriteForCurrentTab()
                    }
                    Button("Show Reader", systemImage: "doc.plaintext") { browser.showReader() }
                    Button("Find on Page", systemImage: "doc.text.magnifyingglass") { browser.findInPage() }
                    Button(tab.isDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
                           systemImage: tab.isDesktopSite ? "iphone" : "desktopcomputer") { browser.toggleDesktopSite() }
                    Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }
                }
                Section {
                    // Safari puts this in the page menu too: the quick fix when blocking breaks a site.
                    Button(browser.blockingDisabledForCurrentSite ? "Turn On Blockers for This Site" : "Turn Off Blockers for This Site",
                           systemImage: browser.blockingDisabledForCurrentSite ? "shield.lefthalf.filled" : "shield.slash") {
                        browser.toggleBlockingForCurrentSite()
                    }
                }
            }
            Section {
                Button("Downloads", systemImage: "arrow.down.circle") { browser.isDownloadsPresented = true }
                Button("Settings", systemImage: "gearshape") { browser.isSettingsPresented = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

/// Reload, or stop while the page is loading. Sits at the trailing end of the address capsule.
struct ReloadButton: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab

    var body: some View {
        Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") {
            tab.isLoading ? browser.stopLoading() : browser.reload()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
    }
}

/// Page load progress: a thin line along the bottom of the address capsule, which clips it.
struct LoadingStrip: View {
    let tab: BrowserTab

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.55))
            .frame(height: 2)
            .scaleEffect(x: max(0.03, tab.estimatedProgress), anchor: .leading)
            .opacity(tab.isLoading ? 1 : 0)
            .animation(Motion.snappy, value: tab.estimatedProgress)
            .animation(Motion.snappy, value: tab.isLoading)
            .allowsHitTesting(false)
    }
}

extension View {
    /// An icon button floating in its own glass circle, the same height as the address capsule.
    func glassCircleButton() -> some View {
        labelStyle(.iconOnly)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Like Safari, a web form's keyboard takes the bar's place rather than pushing it up the page.
    func hiddenWhileKeyboardIsUp() -> some View { modifier(HiddenWhileKeyboardIsUp()) }
}

private struct HiddenWhileKeyboardIsUp: ViewModifier {
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .opacity(keyboardUp ? 0 : 1)
            .allowsHitTesting(!keyboardUp)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(Motion.snappy) { keyboardUp = false }
            }
    }
}
