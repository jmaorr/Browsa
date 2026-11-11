import SwiftUI
import BrowserCore

/// The menu bar. Keys come from `Shortcuts` (Settings › Shortcuts): Arc's by default, or Chrome's
/// or Safari's, plus your own changes. Menus act on the key window's browser; with no window
/// open, the ones that need one are off.
struct BrowserCommands: Commands {
    let library: Library
    let updates: Updates
    @FocusedValue(\.browser) private var focused

    private var browser: Browser? { focused ?? library.activeWindow }
    private var tab: BrowserTab? { browser?.currentTab }
    private var hasPage: Bool { tab?.url != nil }
    private var keys: Shortcuts { Shortcuts.shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.isEnabled {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { newTab(.newTab) }
                .keyboardShortcut(keys.shortcut(.newTab))
            Button("New Window") { library.openWindow() }
                .keyboardShortcut(keys.shortcut(.newWindow))
            Button("New Private Tab") {
                if let browser { browser.run(command: "private") } else { library.openWindow(.privateTab) }
            }
            .keyboardShortcut(keys.shortcut(.privateTab))
            Button("Open Location…") { newTab(.editCurrent) }
                .keyboardShortcut(keys.shortcut(.openLocation))
            Button("Commands and Tools") { newTab(.commands) }
                .keyboardShortcut(keys.shortcut(.commands))
            Divider()
            Button("Close Tab") { if let browser, let tab { withAnimation(Motion.snappy) { browser.close(tab) } } }
                .keyboardShortcut(keys.shortcut(.close))
                .disabled(tab == nil)
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut(keys.shortcut(.reopen))
                .disabled(browser == nil || library.recentlyClosed.isEmpty)
            Button("Move Tab to New Window") { if let tab { browser?.openInNewWindow(tab) } }
                .disabled(tab == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") { browser?.copyCurrentLink() }
                .keyboardShortcut(keys.shortcut(.copyLink))
                .disabled(!hasPage)
            Button("Copy Link as Markdown") { browser?.copyCurrentLinkAsMarkdown() }
                .keyboardShortcut(keys.shortcut(.copyMarkdown))
                .disabled(!hasPage)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { browser?.showFind() }
                .keyboardShortcut(keys.shortcut(.find))
                .disabled(!hasPage)
            Button("Find Next") { browser?.findNext() }
                .keyboardShortcut(keys.shortcut(.findNext))
                .disabled(browser?.find == nil)
            Button("Find Previous") { browser?.findNext(backwards: true) }
                .keyboardShortcut(keys.shortcut(.findPrevious))
                .disabled(browser?.find == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(browser?.isSidebarDocked == false ? "Show Sidebar" : "Hide Sidebar") {
                guard let browser else { return }
                browser.toggleSidebar()
            }
            .keyboardShortcut(keys.shortcut(.sidebar))
            .disabled(browser == nil)
            Button(browser?.panel == nil ? "Show Panel" : "Hide Panel") { browser?.togglePanel() }
                .keyboardShortcut(keys.shortcut(.panel))
                .disabled(browser == nil)
            Button("Notes") { browser?.showPanel("notes", toggles: true) }
                .keyboardShortcut(keys.shortcut(.notes))
                .disabled(browser == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(browser?.isReaderShowing == true ? "Hide Reader" : "Show Reader") { browser?.toggleReader() }
                .keyboardShortcut(keys.shortcut(.reader))
                .disabled(!hasPage)
            Divider()
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut(keys.shortcut(.reload))
                .disabled(!hasPage)
            Button("Reload Without Cache") { browser?.reloadFromOrigin() }
                .keyboardShortcut(keys.shortcut(.hardReload))
                .disabled(!hasPage)
            Button("Stop") { browser?.stopLoading() }
                .keyboardShortcut(keys.shortcut(.stop))
                .disabled(tab?.isLoading != true)
            Divider()
            Button("Zoom In") { browser?.zoom(1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { browser?.zoom(-1) }
                .keyboardShortcut("-")
            Button("Actual Size") { browser?.zoom(0) }
                .keyboardShortcut("0")
            Divider()
            Button(browser?.blockingDisabledForCurrentSite == true ? "Turn Blockers On for This Site" : "Turn Blockers Off for This Site") {
                browser?.toggleBlockingForCurrentSite()
            }
            .disabled(!hasPage)
            Button("Web Inspector") { browser?.showWebInspector() }
                .keyboardShortcut(keys.shortcut(.inspector))
                .disabled(!hasPage)
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut(keys.shortcut(.back))
                .disabled(tab?.canGoBack != true && browser?.isReaderShowing != true)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut(keys.shortcut(.forward))
                .disabled(tab?.canGoForward != true)
            Divider()
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .disabled(browser == nil || library.recentlyClosed.isEmpty)
            Button("Archived Tabs…") { browser?.isArchivePresented = true }
                .keyboardShortcut(keys.shortcut(.archive))
                .disabled(browser == nil)
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { browser?.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { browser?.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { browser?.selectAdjacentTab(1) }
                .keyboardShortcut(keys.shortcut(.nextTab))
            Button("Previous Tab") { browser?.selectAdjacentTab(-1) }
                .keyboardShortcut(keys.shortcut(.previousTab))
            Divider()
            Button(tab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let browser, let tab { withAnimation(Motion.snappy) { browser.togglePinned(tab) } }
            }
            .keyboardShortcut(keys.shortcut(.pin))
            .disabled(tab == nil || tab?.isPrivate == true)
            Button(tab?.url.map { library.isFavorite($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                browser?.toggleFavoriteForCurrentTab()
            }
            .keyboardShortcut(keys.shortcut(.favourite))
            .disabled(!hasPage)
            Button("Close Other Tabs") { if let browser, let tab { browser.closeOtherTabs(than: tab) } }
                .keyboardShortcut(keys.shortcut(.closeOthers))
                .disabled((browser?.currentSpace.today.count ?? 0) < 2)
            Button("Clear Today's Tabs") { if let browser { withAnimation(Motion.snappy) { browser.clearToday() } } }
                .keyboardShortcut(keys.shortcut(.clearToday))
                .disabled(browser?.currentSpace.listedToday.contains { $0.id != tab?.id } != true)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser?.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Spaces") {
            Button("Next Space") { browser?.selectAdjacentSpace(1) }
                .keyboardShortcut(keys.shortcut(.nextSpace))
            Button("Previous Space") { browser?.selectAdjacentSpace(-1) }
                .keyboardShortcut(keys.shortcut(.previousSpace))
            Divider()
            ForEach(Array(library.spaces.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button(s.name) { browser?.selectSpace(number: i + 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
            Divider()
            Button("New Space") {
                if let browser { browser.addSpace() } else { library.addSpace() }
            }
            Button("Close Private Tabs") { library.closePrivateSpace() }
                .disabled(library.privateSpace == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Welcome to Browsa") { browser?.openWelcome(playingIntro: true) }
                .disabled(browser == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Downloads") { browser?.showPanel("downloads", toggles: true) }
                .keyboardShortcut(keys.shortcut(.downloads))
                .disabled(browser == nil)
            Divider()
        }
    }

    /// Cmd-T and friends. With every window closed they open a fresh one.
    private func newTab(_ mode: CommandBarMode) {
        if let browser { browser.showCommandBar(mode) } else { library.openWindow() }
    }
}
