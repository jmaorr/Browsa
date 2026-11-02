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
        let canGo = forward ? (tab?.canGoForward ?? false) : (tab?.canGoBack ?? false)
        // The page is out of sight behind the tab gallery.
        let enabled = canGo && !browser.tabGridCoversPage
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

/// Opens and closes the tab gallery. Holds no count, so it reads the same however many tabs are open.
/// While the gallery is up it turns into a tick that closes it, so the gallery needs no Done button.
struct TabsButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let open = browser.isTabSwitcherPresented
        Button { browser.isTabSwitcherPresented.toggle() } label: {
            Label(open ? "Done" : "Tabs", systemImage: open ? "checkmark" : "square.on.square")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityValue(open ? "" : "\(browser.currentSpace.allTabs.count) open")
        .sensoryFeedback(.selection, trigger: open)
    }
}

/// Shows in the toolbar while something downloads. A ring fills around the arrow (a spinner if the
/// server didn't give a size), then a tick shows for 5 s and a plain downloads icon for the rest of two minutes (a failure keeps
/// its warning throughout). Tap for the downloads list.
struct DownloadProgressButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let progress = browser.downloads.runningProgress
        // Newest first, so this is whichever download ended last.
        let failed = browser.downloads.items.first.map { if case .failed = $0.state { true } else { false } } ?? false
        Button { browser.isDownloadsPresented = true } label: {
            ZStack {
                if let progress, progress == 0 {
                    ProgressView().controlSize(.small)
                } else if let progress {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.snappy, value: progress)
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                } else {
                    Image(systemName: failed ? "exclamationmark.circle.fill"
                          : browser.downloads.isShowingFinishTick ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 22))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 22, height: 22)
            .animation(Motion.bouncy, value: progress == nil)
        }
        .accessibilityLabel("Downloads")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? (failed ? "Failed" : "Finished"))
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
            .fill(.blue)
            .frame(height: 3)
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
            .frame(width: BarMetrics.capsuleHeight, height: BarMetrics.capsuleHeight)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Like Safari, a web form's keyboard takes the bar's place rather than pushing it up the page.
    func hiddenWhileKeyboardIsUp() -> some View { modifier(HiddenWhileKeyboardIsUp()) }
}

private struct HiddenWhileKeyboardIsUp: ViewModifier {
    @State private var keyboardUp = false
    @Environment(\.posture) private var posture

    func body(content: Content) -> some View {
        content
            .opacity(keyboardUp ? 0 : 1)
            .allowsHitTesting(!keyboardUp)
            // The frame, not show/hide: folding or unfolding with a field focused can move the
            // keyboard between displays without a matching hide, which used to leave the bar gone.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let up = Self.isOnScreen(note)
                guard up != keyboardUp else { return }
                if up { keyboardUp = true } else { withAnimation(Motion.snappy) { keyboardUp = false } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(Motion.snappy) { keyboardUp = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                keyboardUp = false
            }
            // A new display: if the keyboard is still up there, it says so again.
            .onChange(of: posture) { keyboardUp = false }
    }

    private static func isOnScreen(_ note: Notification) -> Bool {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        // A hardware keyboard leaves only a short shortcuts bar, which doesn't cover the bar.
        let screen = (note.object as? UIScreen)?.bounds ?? end
        return end.height > 80 && end.minY < screen.maxY - 1
    }
}
