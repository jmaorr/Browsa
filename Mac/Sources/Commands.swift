import SwiftUI
import BrowserCore

/// The menu bar. Every action has a key, most of them the same as Arc's or Safari's.
struct BrowserCommands: Commands {
    let browser: Browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.showCommandBar(.newTab) }
                .keyboardShortcut("t")
            Button("New Private Tab") { browser.run(command: "private") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Location…") { browser.showCommandBar(.editCurrent) }
                .keyboardShortcut("l")
            Button("Command Bar") { browser.showCommandBar(.newTab) }
                .keyboardShortcut("k")
            Divider()
            Button("Close Tab") { if let t = browser.currentTab { withAnimation(Motion.snappy) { browser.close(t) } } }
                .keyboardShortcut("w")
                .disabled(browser.currentTab == nil)
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(browser.recentlyClosed.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") { browser.copyCurrentLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(browser.currentTab?.url == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { browser.showFind() }
                .keyboardShortcut("f")
                .disabled(browser.currentTab?.url == nil)
            Button("Find Next") { browser.findNext() }
                .keyboardShortcut("g")
                .disabled(browser.find == nil)
            Button("Find Previous") { browser.findNext(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser.find == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(browser.isSidebarDocked ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(Motion.spring) { browser.toggleSidebar() }
            }
            .keyboardShortcut("s")
        }

        CommandGroup(before: .toolbar) {
            Button("Reload Page") { browser.reload() }
                .keyboardShortcut("r")
                .disabled(browser.currentTab?.url == nil)
            Button("Reload Without Cache") { browser.reloadFromOrigin() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(browser.currentTab?.url == nil)
            Button("Stop") { browser.stopLoading() }
                .keyboardShortcut(".")
                .disabled(browser.currentTab?.isLoading != true)
            Divider()
            Button("Zoom In") { browser.zoom(1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { browser.zoom(-1) }
                .keyboardShortcut("-")
            Button("Actual Size") { browser.zoom(0) }
                .keyboardShortcut("0")
            Divider()
            Button(browser.blockingDisabledForCurrentSite ? "Turn Blockers On for This Site" : "Turn Blockers Off for This Site") {
                browser.toggleBlockingForCurrentSite()
            }
            .disabled(browser.currentTab?.url == nil)
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { browser.goBack() }
                .keyboardShortcut("[")
                .disabled(browser.currentTab?.canGoBack != true)
            Button("Forward") { browser.goForward() }
                .keyboardShortcut("]")
                .disabled(browser.currentTab?.canGoForward != true)
            Divider()
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                .disabled(browser.recentlyClosed.isEmpty)
            Button("Archived Tabs…") { browser.isArchivePresented = true }
                .keyboardShortcut("y")
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { browser.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { browser.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button(browser.currentTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let t = browser.currentTab { withAnimation(Motion.snappy) { browser.togglePinned(t) } }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(browser.currentTab == nil || browser.currentTab?.isPrivate == true)
            Button(browser.currentTab?.url.map { browser.isFavorite($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                browser.toggleFavoriteForCurrentTab()
            }
                .keyboardShortcut("d")
                .disabled(browser.currentTab?.url == nil)
            Button("Close Other Tabs") { if let t = browser.currentTab { browser.closeOtherTabs(than: t) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(browser.currentSpace.today.count < 2)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Spaces") {
            Button("Next Space") { browser.selectAdjacentSpace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { browser.selectAdjacentSpace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(Array(browser.spaces.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button(s.name) { browser.selectSpace(number: i + 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
            Divider()
            Button("New Space") { browser.addSpace() }
            if browser.privateSpace != nil {
                Button("Close Private Tabs") { browser.closePrivateSpace() }
            }
        }

        CommandGroup(before: .windowList) {
            Button("Downloads") { browser.isDownloadsPresented.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
        }
    }
}
