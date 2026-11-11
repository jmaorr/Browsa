import SwiftUI
import AppKit
import WebKitEngine
import BrowserCore

@main
struct BrowsaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before anything opens a store: bring data over from the old sandbox container, once.
        SandboxMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: "browser") {
            WindowRoot(library: appDelegate.library)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // A new window fills the screen's free space (inside the menu bar and Dock), not a small box.
        // Restored windows get the same treatment in WindowSizing until the person sizes one.
        .defaultWindowPlacement { _, context in
            WindowPlacement(context.defaultDisplay.visibleRect.origin, size: context.defaultDisplay.visibleRect.size)
        }
        // Left to itself, SwiftUI answers a link from another app by opening a new window. Claim no
        // external events here, so links reach the app delegate and open as tabs instead.
        .handlesExternalEvents(matching: [])
        .commands { BrowserCommands(library: appDelegate.library, updates: appDelegate.updates) }

        Settings {
            SettingsView()
                .environment(appDelegate.library)
                .environment(appDelegate.updates)
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
    /// Sparkle, in release builds only. Made with the delegate so it starts as the app launches.
    let updates = Updates()
    /// The window in use, for the debug tour.
    var browser: Browser? { library.activeWindow }
    private var isClearingForQuit = false

    private static func makeLibrary() -> Library {
        #if SPIKE
        SpikeHarness.willMakeLibrary()
        #endif
        #if DEBUG
        // The snapshot tour starts from a fresh state and leaves the real one alone.
        if ProcessInfo.processInfo.environment["BROWSA_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["BROWSA_COLUMNS_CHECK"] != nil
            || ProcessInfo.processInfo.environment["BROWSA_DROP_CHECK"] != nil
            || ProcessInfo.processInfo.environment["BROWSA_AGENT_GATE_CHECK"] != nil
            || ProcessInfo.processInfo.environment["BROWSA_RADAR_CHECK"] != nil {
            return Library(engine: WebKitEngine(), history: HistoryStore(fileURL: nil), snapshotURL: nil)
        }
        #endif
        return Library(engine: WebKitEngine())
    }
    private var keyMonitor: Any?
    private var archiveTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sign-ins from the sandbox days, once. Pages that loaded before they're in reload.
        CookieImport.runIfNeeded { [weak self] in
            guard let library = self?.library else { return }
            for tab in library.allTabs { library.existingController(for: tab)?.page.reload() }
        }
        // Keys menus can't take: Cmd-= zooms (the menu shows Cmd-+), Close Tab's key closes the tab
        // rather than the window while a tab is open, and actions' second keys.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
        #if SPIKE
        SpikeHarness.start(delegate: self)
        #endif
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_CHECK"] {
            Task { @MainActor in await ExtensionCompatCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_PILL_CHECK"] {
            Task { @MainActor in await PillCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_DROP_CHECK"] {
            Task { @MainActor in await DropCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_COLUMNS_CHECK"] {
            Task { @MainActor in await ColumnsCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let mode = ProcessInfo.processInfo.environment["BROWSA_MIGRATION_CHECK"] {
            Task { @MainActor in await MigrationCheck(mode: mode, delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_RADAR_CHECK"] {
            Task { @MainActor in await RadarCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["BROWSA_AGENT_GATE_CHECK"] {
            Task { @MainActor in await AgentGateCheck(directory: URL(fileURLWithPath: dir), delegate: self).run() }
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
        let shortcuts = Shortcuts.shared
        // Pages that take ⌘S for themselves (Save in Docs, Notion, Figma…) would otherwise swallow
        // it before the menu sees it, so the sidebar and panel shortcuts are caught here first.
        if shortcuts.matches(.sidebar, event), browser.commandBar == nil {
            withAnimation(Motion.dock) { browser.toggleSidebar() }
            return true
        }
        if shortcuts.matches(.panel, event) {
            browser.togglePanel()
            return true
        }
        // A menu item shows one key; an action's other keys (⇧⌘] beside ⌥⌘↓) are handled here.
        if let action = shortcuts.isAlternate(event), action != .close {
            browser.perform(action)
            return true
        }
        if shortcuts.matches(.close, event) {
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
