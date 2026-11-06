import AppKit
import BrowserCore
import BrowserEngine
import Suggest

extension Browser {
    // MARK: Command bar

    func showCommandBar(_ mode: CommandBarMode) {
        // Editing needs a page; with none it's just a new tab.
        commandBar = mode == .editCurrent && currentTab == nil ? .newTab : mode
    }

    /// A picked suggestion, favourite or Return in the command bar.
    func perform(_ action: SuggestionAction, mode: CommandBarMode, source: Frecency.VisitSource = .typed) {
        commandBar = nil
        switch action {
        case .switchToTab(let id, _):
            if let tab = spaces.flatMap(\.allTabs).first(where: { $0.id == id }) { select(tab) }
            else if let tab = archive.first(where: { $0.id == id }) { restoreFromArchive(tab) }
        case .open(let url):
            navigate(to: url, replacing: mode == .editCurrent, source: source)
        case .search(let q):
            navigate(to: settings.searchEngine.searchURL(for: q), replacing: mode == .editCurrent, source: source)
        case .command(let id):
            run(command: id)
        }
    }

    func navigate(to url: URL, replacing: Bool, source: Frecency.VisitSource) {
        if replacing, let tab = currentTab {
            controller(for: tab).load(url, source: source)
        } else {
            newTab(url: url, source: source)
        }
    }

    /// Commands that make sense right now, matched by what you type in the command bar.
    func availableCommands() -> [BrowserCommand] {
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
                out.append(BrowserCommand(id: "reload", title: "Reload Page", keywords: ["refresh"]))
                out.append(BrowserCommand(id: "find", title: "Find on Page", keywords: ["search", "text"]))
                out.append(BrowserCommand(id: "zoom-in", title: "Zoom In", keywords: ["bigger", "larger", "text size"]))
                out.append(BrowserCommand(id: "zoom-out", title: "Zoom Out", keywords: ["smaller", "text size"]))
                out.append(BrowserCommand(id: "zoom-reset", title: "Actual Size", keywords: ["zoom", "reset"]))
                out.append(BrowserCommand(id: "blockers", title: blockingDisabledForCurrentSite ? "Turn Blockers On for This Site" : "Turn Blockers Off for This Site",
                                          keywords: ["ads", "adblock", "trackers", "content blocker"]))
                out.append(BrowserCommand(id: "share", title: "Share…", keywords: ["send"]))
            }
            for s in regularSpaces where s.id != selectedSpaceID && !tab.isPrivate {
                out.append(BrowserCommand(id: "move:" + s.id.uuidString, title: "Move Tab to \(s.name)", subtitle: "Space", keywords: ["space"]))
            }
        }
        if currentSpace.today.count > 1 {
            out.append(BrowserCommand(id: "close-others", title: "Close Other Tabs", keywords: ["tabs", "clean"]))
        }
        if let last = recentlyClosed.last {
            out.append(BrowserCommand(id: "reopen", title: "Reopen Closed Tab", subtitle: last.displayTitle, keywords: ["undo", "restore"]))
        }
        out.append(BrowserCommand(id: "sidebar", title: isSidebarDocked ? "Hide Sidebar" : "Show Sidebar", keywords: ["toggle"]))
        out.append(BrowserCommand(id: "private", title: "New Private Tab", keywords: ["incognito"]))
        if let p = privateSpace {
            out.append(BrowserCommand(id: "close-private", title: "Close Private Tabs", subtitle: "\(p.allTabs.count) tabs",
                                      keywords: ["incognito", "private", "clear"]))
        }
        for s in spaces where s.id != selectedSpaceID {
            out.append(BrowserCommand(id: "space:" + s.id.uuidString, title: "Switch to \(s.name)", subtitle: "Space", keywords: ["space"]))
        }
        out.append(BrowserCommand(id: "new-space", title: "New Space", keywords: ["space", "profile"]))
        if !downloads.isEmpty {
            out.append(BrowserCommand(id: "downloads", title: "Show Downloads", subtitle: "\(downloads.count) files", keywords: ["files"]))
        }
        out.append(BrowserCommand(id: "archive", title: "Show Archive", subtitle: "\(archive.count) archived tabs", keywords: ["history", "closed"]))
        out.append(BrowserCommand(id: "settings", title: "Settings", keywords: ["preferences", "search engine"]))
        return out
    }

    func run(command id: String) {
        commandBar = nil
        switch id {
        case "pin": if let t = currentTab { togglePinned(t) }
        case "favourite": if let t = currentTab, let url = t.url { addFavorite(url: url, title: t.displayTitle) }
        case "close": if let t = currentTab { close(t) }
        case "copy-link": copyCurrentLink()
        case "reload": reload()
        case "find": showFind()
        case "zoom-in": zoom(1)
        case "zoom-out": zoom(-1)
        case "zoom-reset": zoom(0)
        case "blockers": toggleBlockingForCurrentSite()
        case "share": shareCurrentPage()
        case "close-others": if let t = currentTab { closeOtherTabs(than: t) }
        case "reopen": reopenClosedTab()
        case "sidebar": toggleSidebar()
        case "private": newTab(url: nil, isPrivate: true); showCommandBar(.editCurrent)
        case "close-private": closePrivateSpace()
        case "new-space": addSpace()
        case "downloads": isDownloadsPresented = true
        case "archive": isArchivePresented = true
        case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            if id.hasPrefix("space:"), let uuid = UUID(uuidString: String(id.dropFirst(6))),
               let s = spaces.first(where: { $0.id == uuid }) {
                selectSpace(s)
            } else if id.hasPrefix("move:"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
                      let s = spaces.first(where: { $0.id == uuid }), let t = currentTab {
                move(t, to: s)
                showToast("Moved to \(s.name)")
            } else if id.hasPrefix("restore:"), let uuid = UUID(uuidString: String(id.dropFirst(8))),
                      let t = archive.first(where: { $0.id == uuid }) {
                restoreFromArchive(t)
            }
        }
    }

    // MARK: Page actions

    func goBack() { currentController?.page.goBack() }
    func goForward() { currentController?.page.goForward() }

    func reload() {
        guard let c = currentController else { return }
        c.tab.loadError = nil
        c.page.reload()
    }

    func reloadFromOrigin() { currentController?.page.reloadFromOrigin() }
    func stopLoading() { currentController?.page.stopLoading() }

    /// Cmd-+ / Cmd-- / Cmd-0. Remembered per site.
    func zoom(_ direction: Int) {
        guard engine.info.capabilities.contains(.pageZoom), currentTab?.url != nil else { return }
        currentController?.zoom(by: direction)
    }

    var currentZoom: Double { currentTab.flatMap { controllers[$0.id]?.page.zoom } ?? 1 }

    func copyCurrentLink() {
        guard let url = currentTab?.url else { return }
        let clean = settings.cleanLinks ? LinkCleaner.cleaned(url) : url
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clean.absoluteString, forType: .string)
        showToast("Link copied")
    }

    func shareCurrentPage() {
        guard let url = currentTab?.url, let view = currentController?.page.view else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    func toggleFavoriteForCurrentTab() {
        guard let tab = currentTab, let url = tab.url else { return }
        let key = URLNormalizer.key(for: url)
        if let f = favorites.first(where: { URLNormalizer.key(for: $0.url) == key }) {
            removeFavorite(f)
            showToast("Removed from Favourites")
        } else {
            addFavorite(url: url, title: tab.displayTitle)
            showToast("Added to Favourites")
        }
    }

    func toggleSidebar() {
        isSidebarDocked.toggle()
        isSidebarPeeking = false
    }

    // MARK: Find

    func showFind() {
        guard currentTab?.url != nil else { return }
        if find == nil { find = FindState() }
        findFocusRequest = UUID()
    }

    func findNext(backwards: Bool = false) {
        guard let text = find?.text, !text.isEmpty, let page = currentController?.page else { showFind(); return }
        Task { @MainActor in
            let found = await page.find(text, backwards: backwards)
            if find?.text == text { find?.found = found }
        }
    }

    func closeFind() {
        currentController?.page.clearFind()
        find = nil
    }
}
