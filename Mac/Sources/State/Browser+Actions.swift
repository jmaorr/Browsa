import AppKit
import SwiftUI
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
        if LibraryPage.isLibrary(url) { openLibrary(LibraryPage.target(url)); return }
        if replacing, let tab = currentTab {
            if isReaderShowing { closeReader() }
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
                out.append(BrowserCommand(id: "reader", title: isReaderShowing ? "Hide Reader" : "Show Reader",
                                          keywords: ["article", "reading", "clean"]))
                out.append(BrowserCommand(id: "tab-window", title: "Move Tab to New Window", keywords: ["window", "detach"]))
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
        out.append(BrowserCommand(id: "new-window", title: "New Window", keywords: ["window"]))
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
        out.append(BrowserCommand(id: "library", title: "Library", keywords: ["extensions", "plugins", "add-ons", "packs", "manage extensions"]))
        out.append(BrowserCommand(id: "settings", title: "Settings", keywords: ["preferences", "search engine"]))
        out.append(BrowserCommand(id: "panel", title: panel == nil ? "Show Panel" : "Hide Panel", keywords: ["right", "side", "tools"]))
        // Every extension with a toolbar button.
        let page = currentController?.page
        for ext in library.actionExtensions {
            let badge = library.actionState(ext, for: page)?.badgeText ?? ""
            out.append(BrowserCommand(id: "ext:" + ext.id, title: "Extension: \(ext.name)", subtitle: badge.isEmpty ? nil : badge,
                                      keywords: ["extension", "add-on"]))
        }
        // Tools add their own: "Open Radar", "Stop All Agents"…
        for (tool, command) in library.workbench.commands {
            out.append(BrowserCommand(id: Workbench.commandID(tool, command), title: command.title,
                                      subtitle: command.subtitle, keywords: command.keywords + [tool.title]))
        }
        return out
    }

    /// The icon a command row shows: the tool's own, or a generic one.
    func symbol(forCommand id: String) -> String {
        if id.hasPrefix("tool:") {
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let entry = library.workbench.commands.first(where: { $0.tool.id == parts[1] && $0.command.id == parts[2] }) {
                return entry.command.symbol ?? entry.tool.symbol
            }
        }
        return Self.commandSymbols[id.split(separator: ":").first.map(String.init) ?? id] ?? "command"
    }

    private static let commandSymbols: [String: String] = [
        "pin": "pin", "favourite": "star", "close": "xmark", "copy-link": "link", "reload": "arrow.clockwise",
        "find": "text.magnifyingglass", "reader": "doc.plaintext", "tab-window": "macwindow.badge.plus",
        "new-window": "macwindow", "zoom-in": "plus.magnifyingglass", "zoom-out": "minus.magnifyingglass",
        "zoom-reset": "1.magnifyingglass", "blockers": "shield", "share": "square.and.arrow.up",
        "close-others": "xmark.square", "reopen": "arrow.uturn.backward", "sidebar": "sidebar.left",
        "panel": "sidebar.right", "private": "eye.slash", "close-private": "eye.slash", "new-space": "plus.rectangle.on.rectangle",
        "downloads": "arrow.down.circle", "archive": "archivebox", "settings": "gearshape", "library": "square.grid.2x2", "space": "square.stack",
        "move": "arrow.right.square", "restore": "archivebox", "ext": "puzzlepiece.extension",
    ]

    func run(command id: String) {
        commandBar = nil
        if library.workbench.run(commandID: id, in: self) { return }
        if id.hasPrefix("ext:"), let ext = library.actionExtensions.first(where: { $0.id == String(id.dropFirst(4)) }) {
            runExtension(ext, anchor: nil)
            return
        }
        switch id {
        case "panel": togglePanel()
        case "pin": if let t = currentTab { togglePinned(t) }
        case "favourite": if let t = currentTab, let url = t.url { addFavorite(url: url, title: t.displayTitle) }
        case "close": if let t = currentTab { close(t) }
        case "copy-link": copyCurrentLink()
        case "reload": reload()
        case "find": showFind()
        case "reader": toggleReader()
        case "tab-window": if let t = currentTab { openInNewWindow(t) }
        case "new-window": library.openWindow()
        case "zoom-in": zoom(1)
        case "zoom-out": zoom(-1)
        case "zoom-reset": zoom(0)
        case "blockers": toggleBlockingForCurrentSite()
        case "share": shareCurrentPage()
        case "close-others": if let t = currentTab { closeOtherTabs(than: t) }
        case "reopen": reopenClosedTab()
        case "sidebar": withAnimation(Motion.dock) { toggleSidebar() }
        case "private": newTab(url: nil, isPrivate: true); showCommandBar(.editCurrent)
        case "close-private": closePrivateSpace()
        case "new-space": addSpace()
        case "downloads": showPanel("downloads")
        case "archive": isArchivePresented = true
        case "library": openLibrary()
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

    func goBack() {
        if isReaderShowing { closeReader(); return }
        currentController?.page.goBack()
    }
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
        if isReaderShowing { reader?.zoom(by: direction); return }
        guard engine.info.capabilities.contains(.pageZoom), currentTab?.url != nil else { return }
        currentController?.zoom(by: direction)
    }

    var currentZoom: Double { currentTab.flatMap { library.existingController(for: $0)?.page.zoom } ?? 1 }

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

    // MARK: Find

    func showFind() {
        guard currentTab?.url != nil, !isReaderShowing else { return }
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
