import SwiftUI
import AppKit
import WebKitEngine
import BrowserCore

@main
struct BrowsaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "browser") {
            WindowRoot(library: appDelegate.library)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(library: appDelegate.library) }

        Settings {
            SettingsView()
                .environment(appDelegate.library)
        }
    }
}

/// One window: makes its `Browser` when it appears and lets it go when it closes.
private struct WindowRoot: View {
    let library: Library
    @State private var browser: Browser?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let browser {
                BrowserWindow()
                    .environment(browser)
                    .focusedSceneValue(\.browser, browser)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            library.openWindowAction = { [openWindow] in openWindow(id: "browser") }
            if browser == nil { browser = Browser(library: library) }
        }
        .onDisappear {
            if let browser { library.unregister(browser) }
        }
    }
}

extension FocusedValues {
    /// The browser in the key window, for the menu bar.
    @Entry var browser: Browser?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// WebKit is the only engine for now. Another one plugs in here (see docs/engines.md).
    lazy var library = AppDelegate.makeLibrary()
    /// The window in use, for the debug tour.
    var browser: Browser? { library.activeWindow }
    private var isClearingForQuit = false

    private static func makeLibrary() -> Library {
        #if DEBUG
        // The snapshot tour starts from a fresh state and leaves the real one alone.
        if ProcessInfo.processInfo.environment["BROWSA_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["BROWSA_COLUMNS_CHECK"] != nil
            || ProcessInfo.processInfo.environment["BROWSA_DROP_CHECK"] != nil {
            return Library(engine: WebKitEngine(), history: HistoryStore(fileURL: nil), snapshotURL: nil)
        }
        #endif
        return Library(engine: WebKitEngine())
    }
    private var keyMonitor: Any?
    private var archiveTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keys menus can't take: Cmd-= zooms (the menu shows Cmd-+), and Cmd-W closes the tab
        // rather than the window while a tab is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_CHECK"] {
            Task { @MainActor in await ExtensionCompatCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_DROP_CHECK"] {
            Task { @MainActor in await DropCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_COLUMNS_CHECK"] {
            Task { @MainActor in await ColumnsCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_SNAPSHOT"] {
            Task { @MainActor in await SnapshotTour(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        #endif
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let library = self?.library else { return }
                library.archiveStaleTabs()
                // Each extension is checked at most once every 20 hours.
                Task { await library.updateExtensions() }
            }
        }
        Task { await library.updateExtensions() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        // Sheets, the settings window and other windows keep their own keys.
        guard let window = event.window, window.attachedSheet == nil,
              let browser = library.window(for: window) else { return false }
        if flags == .command, key == "=" { browser.zoom(1); return true }
        if flags == .command, key == "w" {
            if browser.commandBar != nil { browser.commandBar = nil; return true }
            if let tab = browser.currentTab {
                withAnimation(Motion.snappy) { browser.close(tab) }
                return true
            }
            return false
        }
        if flags.isEmpty, event.keyCode == 53 {   // Escape
            if browser.find != nil { browser.closeFind(); return true }
            if browser.isReaderShowing, browser.commandBar == nil { browser.closeReader(); return true }
            if browser.currentTab?.isLoading == true, browser.commandBar == nil { browser.stopLoading(); return false }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Links from other apps, when Browsa is the default browser. Handled here so they open as
    /// tabs in the window in use rather than in a new window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { library.openExternal(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard library.clearDataOnQuit, !isClearingForQuit else { return .terminateNow }
        // Clearing is asynchronous; quit once it's done (or after a few seconds regardless).
        isClearingForQuit = true
        Task { @MainActor in
            await library.clearHistory()
            await library.clearWebsiteData()
            replyToQuit()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            replyToQuit()
        }
        return .terminateLater
    }

    private var hasRepliedToQuit = false

    private func replyToQuit() {
        guard !hasRepliedToQuit else { return }
        hasRepliedToQuit = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.saveNow()
        library.margin.saveNow()
        library.agents.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        library.saveNow()
    }
}
