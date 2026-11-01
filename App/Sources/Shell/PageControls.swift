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

/// Copy the current page's address, with a haptic and a toast.
struct CopyLinkButton: View {
    @Environment(BrowserState.self) private var browser
    @State private var copies = 0

    var body: some View {
        Button("Copy Link", systemImage: "link") { copy() }
            .disabled(browser.currentTab?.url == nil)
            .sensoryFeedback(.success, trigger: copies)
    }

    func copy() {
        guard let url = browser.currentTab?.url else { return }
        browser.copyToPasteboard(url)
        browser.showToast("Link copied")
        copies += 1
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
                    Button("Find on Page", systemImage: "doc.text.magnifyingglass") { browser.findInPage() }
                    Button(tab.isDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
                           systemImage: tab.isDesktopSite ? "iphone" : "desktopcomputer") { browser.toggleDesktopSite() }
                    Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }
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
