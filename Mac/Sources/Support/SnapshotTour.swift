#if DEBUG
import AppKit
import SwiftUI
import BrowserCore
import BrowserEngine
import Suggest

/// Debug only: with BROWSA_SNAPSHOT=<folder> set, walks through the main screens and saves a PNG of
/// the window at each step, then quits. For checking layouts on a Mac nobody is looking at.
@MainActor
struct SnapshotTour {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Wait for the first window, and say so (and quit) if it never comes, rather than hang.
        var waited = 0.0
        while delegate.browser == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        await pause(2)
        guard let browser = delegate.browser else {
            note("no browser window after 20s; windows: \(NSApp.windows.map { $0.className })")
            NSApp.terminate(nil)
            return
        }
        note("tour started after \(waited)s")
        let library = delegate.library
        // Fetch the favourites' icons first, so the shots show them rather than letters.
        for fav in browser.favorites {
            _ = try? await URLSession.shared.data(from: URL(string: "https://icons.duckduckgo.com/ip3/\(URLNormalizer.displayHost(fav.url)).ico")!)
        }
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
        await pause(1)

        browser.toggleReader()
        await pause(3)
        note("reader showing: \(browser.isReaderShowing) title: \(browser.reader?.article.title ?? "-")")
        save("11-reader")
        if let page = browser.reader?.page { await saveImage(await page.snapshot(), "11-reader-content") }
        browser.zoom(1)
        await pause(1)
        if let page = browser.reader?.page { await saveImage(await page.snapshot(), "11-reader-larger") }
        browser.zoom(0)
        browser.closeReader()
        await pause(1)

        // A second window: its own space and tab, the first window's tabs untouched.
        let firstWindow = browser.nsWindow
        library.openWindow()
        await pause(3)
        let second = library.windows.first { $0 !== browser }
        note("windows: \(library.windows.count), second shows tab: \(second?.currentTab?.displayTitle ?? "none"), command bar: \(String(describing: second?.commandBar))")
        save("12-second-window", in: second?.nsWindow)
        if let second, let tab = browser.currentTab {
            // Moving the first window's tab over: the first window moves on to another tab.
            second.commandBar = nil
            browser.openInNewWindow(tab)
            await pause(3)
            note("after move: windows \(library.windows.count), first shows \(browser.currentTab?.displayTitle ?? "none")")
            save("12-tab-in-window", in: library.window(showing: tab)?.nsWindow)
        }
        for w in library.windows where w !== browser { w.nsWindow?.performClose(nil) }
        await pause(2)
        note("after closing: windows \(library.windows.count)")
        firstWindow?.makeKeyAndOrderFront(nil)
        await pause(1)

        withAnimation(Motion.spring) { browser.selectAdjacentSpace(1) }
        await pause(1)
        save("6-second-space")
        withAnimation(Motion.spring) { browser.selectAdjacentSpace(-1) }

        // The same screens in light mode.
        NSApp.appearance = NSAppearance(named: .aqua)
        await pause(1)
        save("9-light")
        browser.showCommandBar(.newTab)
        await pause(1)
        if let editor = window?.firstResponder as? NSTextView {
            editor.insertText("wiki", replacementRange: editor.selectedRange())
        }
        await pause(2)
        save("10-light-command-bar")
        browser.commandBar = nil
        NSApp.appearance = nil
        await pause(1)

        withAnimation(Motion.dock) { browser.toggleSidebar() }
        await pause(1)
        save("7-sidebar-hidden")
        await savePage(browser, "7-page-content")
        withAnimation(Motion.peek) { browser.isSidebarPeeking = true }
        await pause(1)
        save("8-sidebar-peeking")
        browser.isSidebarPeeking = false
        withAnimation(Motion.dock) { browser.toggleSidebar() }
        await pause(1)

        browser.saveNow()
        NSApp.terminate(nil)
    }

    private var window: NSWindow? {
        delegate.browser?.nsWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    /// A line in report.txt, for things a picture can't show.
    private func note(_ line: String) {
        let url = directory.appending(path: "report.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The window's views drawn into a bitmap. Web content may come out blank this way.
    private func save(_ name: String, in target: NSWindow? = nil) {
        let window = target ?? self.window
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    /// The page itself, from the engine, since window captures can miss it.
    private func savePage(_ browser: Browser, _ name: String) async {
        await saveImage(await browser.currentController?.page.snapshot(), name)
    }

    private func saveImage(_ image: CGImage?, _ name: String) async {
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }
}
#endif
