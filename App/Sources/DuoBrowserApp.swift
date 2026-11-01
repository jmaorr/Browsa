import SwiftUI
import BrowserCore

@main
struct DuoBrowserApp: App {
    @State private var browser = BrowserState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(browser)
                .onAppear { browser.archiveStaleTabs() }
                // Links opened from other apps once this is the default browser.
                .onOpenURL { url in browser.openExternal(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: browser.archiveStaleTabs()
            case .background: browser.saveNow()
            default: break
            }
        }
        .commands {
            // Everything here also shows in the hold-Cmd shortcut overlay.
            CommandGroup(after: .newItem) {
                Button("New Tab") { browser.presentNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Private Tab") {
                    browser.newTab(url: nil, isPrivate: true)
                    browser.presentAddressEditor()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(browser.recentlyClosed.isEmpty)
                Button("Open Location") { browser.presentAddressEditor() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Command Bar") { browser.presentNewTab() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Close Tab") { if let t = browser.currentTab { browser.close(t) } }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Page") {
                Button("Back") { browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!(browser.currentTab?.canGoBack ?? false))
                Button("Forward") { browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!(browser.currentTab?.canGoForward ?? false))
                Button("Reload") { browser.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Stop") { browser.stopLoading() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Find on Page") { browser.findInPage() }
                    .keyboardShortcut("f", modifiers: .command)
                Button(browser.currentTab?.url.map(browser.isFavorite) == true ? "Remove from Favourites" : "Add to Favourites") {
                    browser.toggleFavoriteForCurrentTab()
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("Copy Link") { if let u = browser.currentTab?.url { copyToPasteboard(u) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Tabs") {
                Button("Next Tab") { browser.selectAdjacentTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { browser.selectAdjacentTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Show All Tabs") { browser.isTabSwitcherPresented = true }
                    .keyboardShortcut("\\", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser.selectTab(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
                Button("Downloads") { browser.isDownloadsPresented = true }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("Settings") { browser.isSettingsPresented = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
