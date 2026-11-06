import SwiftUI
import AppKit
import WebKitEngine
import BrowserCore

@main
struct BrowsaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// WebKit is the only engine for now. Another one plugs in here (see docs/engines.md).
    @State private var browser = BrowsaMacApp.makeBrowser()

    private static func makeBrowser() -> Browser {
        #if DEBUG
        // The snapshot tour starts from a fresh state and leaves the real one alone.
        if ProcessInfo.processInfo.environment["BROWSA_SNAPSHOT"] != nil {
            return Browser(engine: WebKitEngine(), history: HistoryStore(fileURL: nil), snapshotURL: nil)
        }
        #endif
        return Browser(engine: WebKitEngine())
    }

    var body: some Scene {
        Window("Browsa", id: "main") {
            BrowserWindow()
                .environment(browser)
                .frame(minWidth: 640, minHeight: 420)
                .onOpenURL { browser.openExternal($0) }
                .onAppear { appDelegate.browser = browser }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(browser: browser) }

        Settings {
            SettingsView()
                .environment(browser)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var browser: Browser?
    private var keyMonitor: Any?
    private var archiveTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keys menus can't take: Cmd-= zooms (the menu shows Cmd-+), and Cmd-W closes the tab
        // rather than the window while a tab is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["BROWSA_SNAPSHOT"] {
            Task { @MainActor in await SnapshotTour(directory: URL(fileURLWithPath: dir), delegate: self).run() }
        }
        #endif
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.browser?.archiveStaleTabs() }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let browser else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        // Sheets, the settings window and other windows keep their own keys.
        guard let window = event.window, window.attachedSheet == nil,
              !(window.identifier?.rawValue.contains("Settings") ?? false) else { return false }
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
            if browser.currentTab?.isLoading == true, browser.commandBar == nil { browser.stopLoading(); return false }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.saveNow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        browser?.saveNow()
    }
}
