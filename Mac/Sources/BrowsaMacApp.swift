import SwiftUI
import AppKit
import WebKit
import WebKitEngine
import BrowserCore

@main
struct BrowsaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // (Browsa's own WebKit, if any, was taken up before main(): PatchedWebKitStart.c.)
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

        // Safari-style toolbar tabs in a preferences title bar.
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
    /// The window's key, kept by SwiftUI with the window so it comes back with its own tabs.
    @SceneStorage("windowKey") private var windowKey = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
            library.openSettingsAction = { [openSettings] in openSettings() }
            if browser == nil {
                let saved = UUID(uuidString: windowKey).flatMap { key in library.windows.contains { $0.windowKey == key } ? nil : key }
                let key = saved ?? UUID()
                windowKey = key.uuidString
                browser = Browser(library: library, windowKey: key, isNewWindow: saved == nil)
            }
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
            || ProcessInfo.processInfo.environment["BROWSA_RADAR_CHECK"] != nil
            // tools/audio-bench: a fresh session, nothing restored or saved. A bench page left in the last session came
            // back and played alongside the new one (2026-11-16, "double looping").
            || AudioBench.isEnabled {
            return Library(engine: WebKitEngine(), history: HistoryStore(fileURL: nil), snapshotURL: nil)
        }
        #endif
        // Before WebKit starts its processes.
        #if DEBUG || BROWSA_CALL_RECORDING
        CallRecordings.applyAtLaunch()
        #endif
        let engine = WebKitEngine()
        let library = Library(engine: engine)
        // Calls (Meet, Zoom, Teams) run in ordinary WebKit tabs: on Browsa's WebKit where it's present, with its call
        // audio in the capture unit; elsewhere on Apple's WebKit. Closing one mid-call asks first.
        CallGuards.install(in: library)
        // Leaving a call's tab floats the call in a small window that follows you; see CallPiP.
        CallPiP.install(in: library)
        return library
    }
    private var keyMonitor: Any?
    private var archiveTimer: Timer?

    /// tools/audio-bench: open its page once a window is up (it can take a moment, and longer while the
    /// screen is locked). Progress goes to stderr, which the bench keeps.
    private func openAudioBenchPage(_ url: URL, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let hasWindow = self.library.activeWindow != nil
            FileHandle.standardError.write(Data("AudioBench: attempt \(attempt), window \(hasWindow)\n".utf8))
            if let window = self.library.activeWindow {
                // A bench page from an earlier run comes back with the session: close it, or two pages play.
                for old in self.library.allTabs where old.url?.path == url.path && ["localhost", "127.0.0.1"].contains(old.url?.host ?? "") {
                    self.library.close(old)
                }
                // Make the page now: tabs normally get theirs when their view first draws, which doesn't
                // happen while the screen is locked.
                let tab = window.newTab(url: url, source: .link)
                _ = self.library.controller(for: tab)
                FileHandle.standardError.write(Data("AudioBench: opened \(url.absoluteString)\n".utf8))
            } else if attempt >= 20 {
                FileHandle.standardError.write(Data("AudioBench: no window, gave up\n".utf8))
            } else {
                self.openAudioBenchPage(url, attempt: attempt + 1)
            }
        }
    }

    /// tools/audio-bench: every `every` seconds, show a blank tab for 2 s and go back, as you might mid-call,
    /// to check the call's audio carries on when its tab isn't in front.
    private func scheduleAudioBenchTabSwitch(every: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + every) { [weak self] in
            guard let self, let window = self.library.activeWindow, let back = window.currentTab else { self?.scheduleAudioBenchTabSwitch(every: every); return }
            let blank = window.newTab(url: URL(string: "about:blank"), source: .link)
            FileHandle.standardError.write(Data("AudioBench: switched away from the call tab\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                window.select(back)
                self.library.close(blank)
                FileHandle.standardError.write(Data("AudioBench: back on the call tab\n".utf8))
                self.scheduleAudioBenchTabSwitch(every: every)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowsaAppearance.apply()
        SiteNotifications.shared.start(library: library)
        // tools/audio-bench opens its page at launch (test builds only; see AudioBench).
        if let url = AudioBench.launchURL { openAudioBenchPage(url, attempt: 0) }
        if let every = AudioBench.tabSwitchSeconds { scheduleAudioBenchTabSwitch(every: every) }
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
        releaseKeysFromDeadPage(in: window, browser: browser)
        if flags == .command, key == "=" { browser.zoom(1); return true }
        let shortcuts = Shortcuts.shared
        // Pages that take ⌘S for themselves (Save in Docs, Notion, Figma…) would otherwise swallow
        // it before the menu sees it, so the sidebar and panel shortcuts are caught here first.
        if shortcuts.matches(.sidebar, event), browser.commandBar == nil {
            browser.toggleSidebar()   // no withAnimation: see toggleSidebar
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

    /// A web view keeps every key press while it's first responder, menu keys included, and hands
    /// the ones the page doesn't use back to the menus once the page has answered. A page whose process
    /// has crashed (Browsa's error page is over it) or hung never answers, so ⌘T, ⌘L, ⌘W, Try Again's
    /// Return, even ⌘Q did nothing. Then the window takes the keys instead, and the menus get them.
    /// A click on the page, or the next tab switch, gives the page the keys back.
    private func releaseKeysFromDeadPage(in window: NSWindow, browser: Browser) {
        var view = window.firstResponder as? NSView
        while let v = view, !(v is WKWebView) { view = v.superview }
        guard let web = view as? WKWebView else { return }
        let behindErrorPage = browser.shownTabs.contains { tab in
            guard tab.loadError != nil, let page = library.existingController(for: tab)?.page.view else { return false }
            return web.isDescendant(of: page)
        }
        guard behindErrorPage || !ProcessSampler.pageCanTakeKeys(web) else { return }
        window.makeFirstResponder(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Links from other apps, when Browsa is the default browser. Handled here so they open as
    /// tabs in the window in use rather than in a new window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { library.openExternal(url) }
        // Launched to open a link (clicked in another app while Browsa was closed), SwiftUI makes no window of its own,
        // and only a window can ask it for one: the link waited for a window that never came. A reopen (what clicking
        // the Dock icon sends) makes SwiftUI open one, which then picks the link up.
        if library.openWindowAction == nil { Self.askForFirstWindow() }
    }

    static func askForFirstWindow() {
        let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
        if let desc = reopen.aeDesc { _ = AESendMessage(desc, nil, AESendMode(kAENoReply), kAEDefaultTimeout) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd-Q in the middle of a meeting would just drop you from it.
        if !isClearingForQuit, !CallGuards.confirmLeaving(CallGuards.tabsInCall(in: library), quitting: true) { return .terminateCancel }
        // From here the app is going: windows that close keep their tabs for next launch.
        library.isTerminating = true
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
