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
                .onOpenURL { url in browser.newTab(url: url, source: .link) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: browser.archiveStaleTabs()
            case .background: browser.saveNow()
            default: break
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { browser.presentNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Open Location") { browser.presentAddressEditor() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Close Tab") { if let t = browser.currentTab { browser.close(t) } }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}
