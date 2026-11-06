#if DEBUG
import AppKit
import SwiftUI
import BrowserEngine

/// Debug only: with BROWSA_SNAPSHOT=<folder> set, walks through the main screens and saves a PNG of
/// the window at each step, then quits. For checking layouts on a Mac nobody is looking at.
@MainActor
struct SnapshotTour {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await pause(3)
        guard let browser = delegate.browser else { return }
        save("1-launch")

        browser.newTab(url: URL(string: "https://www.apple.com")!)
        await pause(6)
        save("2-page")
        await savePage(browser, "2-page-content")

        browser.showCommandBar(.newTab)
        await pause(1)
        save("3-command-bar-empty")
        if let editor = window?.firstResponder as? NSTextView {
            editor.insertText("github", replacementRange: editor.selectedRange())
        }
        await pause(2)
        save("4-command-bar-github")
        browser.commandBar = nil

        browser.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Arc_(web_browser)")!)
        await pause(5)
        browser.zoom(1)
        await pause(1)
        save("5-zoomed")
        browser.zoom(0)

        withAnimation(Motion.spring) { browser.selectAdjacentSpace(1) }
        await pause(1)
        save("6-second-space")
        withAnimation(Motion.spring) { browser.selectAdjacentSpace(-1) }

        withAnimation(Motion.spring) { browser.toggleSidebar() }
        await pause(1)
        save("7-sidebar-hidden")
        await savePage(browser, "7-page-content")
        withAnimation(Motion.peek) { browser.isSidebarPeeking = true }
        await pause(1)
        save("8-sidebar-peeking")
        browser.isSidebarPeeking = false
        withAnimation(Motion.spring) { browser.toggleSidebar() }
        await pause(1)

        browser.saveNow()
        NSApp.terminate(nil)
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The window's views drawn into a bitmap. Web content may come out blank this way.
    private func save(_ name: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    /// The page itself, from the engine, since window captures can miss it.
    private func savePage(_ browser: Browser, _ name: String) async {
        guard let image = await browser.currentController?.page.snapshot() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }
}
#endif
