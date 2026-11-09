#if DEBUG
import AppKit
import BrowserCore

/// Debug only: with BROWSA_MIGRATION_CHECK=seed|verify, checks that leaving the sandbox keeps your
/// data. Build once sandboxed and run `seed`: it opens a page that stores a cookie and local
/// storage, plus a second tab, then quits normally so state saves. Build the same bundle ID
/// unsandboxed and run `verify`: it logs what came across (tabs, extensions, the page's cookie and
/// storage) and, with BROWSA_MIGRATION_SHOT=<file>, leaves the window up for a screenshot.
@MainActor
struct MigrationCheck {
    let mode: String
    let delegate: AppDelegate

    func run() async {
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser else { note("no window"); exit(1) }
        let library = delegate.library
        note("sandboxed=\(AppFolders.isSandboxed) support=\(AppFolders.support.path)")
        let page = URL(string: "http://localhost:5173/store.html")!
        if mode == "seed" {
            browser.newTab(url: URL(string: "http://localhost:5173/store.html#seed")!)
            await pause(3)
            browser.newTab(url: URL(string: "http://localhost:5173/")!)
            await pause(3)
            note("seeded: tabs \(library.allTabs.compactMap(\.url?.absoluteString))")
            NSApp.terminate(nil)
            return
        }
        note("tabs: \(library.allTabs.compactMap(\.url?.absoluteString))")
        for f in library.extensionFolders() {
            note("extension \(f.id): \(f.url.path) exists=\(FileManager.default.fileExists(atPath: f.url.path))")
        }
        if let tab = library.allTabs.first(where: { $0.url?.path == page.path }) {
            browser.select(tab)
            browser.controller(for: tab).page.reload()
        } else {
            browser.newTab(url: page)
        }
        await pause(4)
        let result = try? await browser.currentController?.page.evaluate(
            "return document.cookie + ' | ' + localStorage.getItem('k')", inWorld: "page")
        note("page sees: \(result.map { "\($0)" } ?? "nothing")")
        if let shot = ProcessInfo.processInfo.environment["BROWSA_MIGRATION_SHOT"], let window = browser.nsWindow {
            try? "\(window.windowNumber)".write(toFile: shot, atomically: true, encoding: .utf8)
            await pause(4)
        }
        NSApp.terminate(nil)
    }

    private func note(_ line: String) { FileHandle.standardError.write(Data("[migration-check] \(line)\n".utf8)) }
    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
