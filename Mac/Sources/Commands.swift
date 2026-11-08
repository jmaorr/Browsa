import SwiftUI
import BrowserCore

/// The menu bar. Every action has a key, most of them the same as Arc's or Safari's.
/// Menus act on the key window's browser; with no window open, the ones that need one are off.
struct BrowserCommands: Commands {
    let library: Library
    @FocusedValue(\.browser) private var focused

    private var browser: Browser? { focused ?? library.activeWindow }
    private var tab: BrowserTab? { browser?.currentTab }
    private var hasPage: Bool { tab?.url != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { newTab(.newTab) }
                .keyboardShortcut("t")
            Button("New Window") { library.openWindow() }
                .keyboardShortcut("n")
            Button("New Private Tab") {
                if let browser { browser.run(command: "private") } else { library.openWindow(.privateTab) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Location…") { newTab(.editCurrent) }
                .keyboardShortcut("l")
            Button("Command Bar") { newTab(.newTab) }
                .keyboardShortcut("k")
            Divider()
            Button("Close Tab") { if let browser, let tab { withAnimation(Motion.snappy) { browser.close(tab) } } }
                .keyboardShortcut("w")
                .disabled(tab == nil)
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(browser == nil || library.recentlyClosed.isEmpty)
            Button("Move Tab to New Window") { if let tab { browser?.openInNewWindow(tab) } }
                .disabled(tab == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") { browser?.copyCurrentLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasPage)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { browser?.showFind() }
                .keyboardShortcut("f")
                .disabled(!hasPage)
            Button("Find Next") { browser?.findNext() }
                .keyboardShortcut("g")
                .disabled(browser?.find == nil)
            Button("Find Previous") { browser?.findNext(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser?.find == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(browser?.isSidebarDocked == false ? "Show Sidebar" : "Hide Sidebar") {
                guard let browser else { return }
                withAnimation(Motion.dock) { browser.toggleSidebar() }
            }
            .keyboardShortcut("s")
            .disabled(browser == nil)
            Button(browser?.panel == nil ? "Show Panel" : "Hide Panel") { browser?.togglePanel() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(browser == nil)
            Button("Notes") { browser?.togglePanel(.margin) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Button("Agents") { browser?.togglePanel(.agents) }
                .disabled(browser == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(browser?.isReaderShowing == true ? "Hide Reader" : "Show Reader") { browser?.toggleReader() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasPage)
            Divider()
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(!hasPage)
            Button("Reload Without Cache") { browser?.reloadFromOrigin() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!hasPage)
            Button("Stop") { browser?.stopLoading() }
                .keyboardShortcut(".")
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
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[")
                .disabled(tab?.canGoBack != true && browser?.isReaderShowing != true)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]")
                .disabled(tab?.canGoForward != true)
            Divider()
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .disabled(browser == nil || library.recentlyClosed.isEmpty)
            Button("Archived Tabs…") { browser?.isArchivePresented = true }
                .keyboardShortcut("y")
                .disabled(browser == nil)
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { browser?.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { browser?.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { browser?.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser?.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button(tab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let browser, let tab { withAnimation(Motion.snappy) { browser.togglePinned(tab) } }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(tab == nil || tab?.isPrivate == true)
            Button(tab?.url.map { library.isFavorite($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                browser?.toggleFavoriteForCurrentTab()
            }
            .keyboardShortcut("d")
            .disabled(!hasPage)
            Button("Close Other Tabs") { if let browser, let tab { browser.closeOtherTabs(than: tab) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled((browser?.currentSpace.today.count ?? 0) < 2)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser?.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Spaces") {
            Button("Next Space") { browser?.selectAdjacentSpace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { browser?.selectAdjacentSpace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
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

        CommandGroup(before: .windowList) {
            Button("Downloads") { browser?.isDownloadsPresented.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(browser == nil)
            Divider()
        }
    }

    /// Cmd-T and friends. With every window closed they open a fresh one.
    private func newTab(_ mode: CommandBarMode) {
        if let browser { browser.showCommandBar(mode) } else { library.openWindow() }
    }
}
