#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

extension BrowserState {
    // MARK: Command bar

    /// Commands that make sense right now, for the command bar.
    public func availableCommands() -> [BrowserCommand] {
        var out: [BrowserCommand] = []
        if let tab = currentTab {
            if !tab.isPrivate {
                out.append(BrowserCommand(id: "pin", title: tab.isPinned ? "Unpin Tab" : "Pin Tab", keywords: ["tab"]))
            }
            if let url = tab.url, !isFavorite(url) {
                out.append(BrowserCommand(id: "favourite", title: "Add to Favourites", subtitle: tab.displayTitle,
                                          keywords: ["favorite", "star", "bookmark"]))
            }
            out.append(BrowserCommand(id: "close", title: "Close Tab", keywords: ["tab"]))
            if let url = tab.url {
                out.append(BrowserCommand(id: "copy-link", title: "Copy Link", subtitle: url.absoluteString, keywords: ["url", "share"]))
            }
        }
        if currentSpace.today.count > 1 {
            out.append(BrowserCommand(id: "close-others", title: "Close Other Tabs", keywords: ["tabs", "clean"]))
        }
        if let last = recentlyClosed.last {
            out.append(BrowserCommand(id: "reopen", title: "Reopen Closed Tab", subtitle: last.displayTitle, keywords: ["undo", "restore"]))
        }
        if let tab = currentTab, tab.url != nil {
            out.append(BrowserCommand(id: "desktop", title: tab.isDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
                                      keywords: ["desktop", "mobile", "user agent"]))
            out.append(BrowserCommand(id: "find", title: "Find on Page", keywords: ["search", "text"]))
            out.append(BrowserCommand(id: "reload", title: "Reload Page", keywords: ["refresh"]))
        }
        if !downloads.items.isEmpty {
            out.append(BrowserCommand(id: "downloads", title: "Show Downloads", subtitle: "\(downloads.items.count) files", keywords: ["files"]))
        }
        out.append(BrowserCommand(id: "private", title: "New Private Tab", keywords: ["incognito"]))
        if let p = privateSpace {
            out.append(BrowserCommand(id: "close-private", title: "Close Private Tabs", subtitle: "\(p.allTabs.count) tabs",
                                      keywords: ["incognito", "private", "clear"]))
        }
        for s in spaces where s.id != selectedSpaceID {
            out.append(BrowserCommand(id: "space:" + s.id.uuidString, title: "Switch to \(s.name)", subtitle: "Space", keywords: ["space"]))
        }
        out.append(BrowserCommand(id: "settings", title: "Settings", keywords: ["preferences", "search engine"]))
        out.append(BrowserCommand(id: "archive", title: "Show Archive", subtitle: "\(archive.count) archived tabs", keywords: ["history", "closed"]))
        return out
    }

    public func run(command id: String) {
        isNewTabSheetPresented = false
        switch id {
        case "pin": if let t = currentTab { togglePinned(t) }
        case "favourite": if let t = currentTab, let url = t.url { addFavorite(url: url, title: t.displayTitle) }
        case "close": if let t = currentTab { close(t) }
        case "copy-link": if let url = currentTab?.url { copyToPasteboard(url) }
        case "close-others":
            let keep = currentTab?.id
            for t in currentSpace.today where t.id != keep { close(t) }
        case "private":
            newTab(url: nil, isPrivate: true)
            presentAddressEditor()
        case "close-private": closePrivateSpace()
        case "reopen": reopenClosedTab()
        case "find":
            // Wait for the sheet to finish dismissing so the find bar can take first responder.
            Task { try? await Task.sleep(for: .milliseconds(350)); findInPage() }
        case "reload": reload()
        case "desktop": toggleDesktopSite()
        case "downloads": isDownloadsPresented = true
        case "settings": isSettingsPresented = true
        case "archive": isArchivePresented = true
        default:
            if id.hasPrefix("space:"), let uuid = UUID(uuidString: String(id.dropFirst(6))),
               let s = spaces.first(where: { $0.id == uuid }) {
                selectSpace(s)
            } else if id.hasPrefix("restore:"), let uuid = UUID(uuidString: String(id.dropFirst(8))),
                      let t = archive.first(where: { $0.id == uuid }) {
                restoreFromArchive(t)
            }
        }
    }

    func navigate(to url: URL, reuseCurrent: Bool, source: Frecency.VisitSource) {
        if reuseCurrent, let tab = currentTab {
            session(for: tab).load(url, source: source)
        } else {
            newTab(url: url, source: source)
        }
    }

    func openPopup(url: URL, configuration: WKWebViewConfiguration, from opener: BrowserTab) -> WKWebView {
        let space = spaces.first { $0.allTabs.contains { $0.id == opener.id } } ?? currentSpace
        let tab = BrowserTab(url: url, isPrivate: opener.isPrivate)
        space.today.insert(tab, at: 0)
        let s = TabSession(tab: tab, configuration: configuration, browser: self, loadInitial: false)
        pool.adopt(s)
        select(tab)
        return s.webView
    }
}
#endif
