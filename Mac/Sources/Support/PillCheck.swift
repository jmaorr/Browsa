#if DEBUG
import AppKit
import BrowserEngine

/// Debug only: with BROWSA_PILL_CHECK=<folder>, installs the store extensions in BROWSA_EXT_COMPAT_IDS
/// (if not already there), opens a login page, and records the address pill: which extensions are
/// pinned, each one's action state for the page, the ⌘K extension commands, and window images.
@MainActor
struct PillCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser, let window = browser.nsWindow else { note("no window"); exit(1) }
        let library = delegate.library
        let ids = (ProcessInfo.processInfo.environment["BROWSA_EXT_COMPAT_IDS"] ?? "").split(separator: " ").map(String.init)
        for id in ids where !library.extensionCatalog.items.contains(where: { $0.id.hasSuffix(id) }) {
            if let preview = try? await library.previewExtension(link: id) { library.extensionCatalog.upsert(preview.item) }
        }
        library.reloadExtensions()
        await pause(12)
        for (name, url) in [("github", "https://github.com/login"), ("ads", "https://www.theverge.com")] {
            browser.newTab(url: URL(string: url)!)
            await pause(10)
            let page = browser.currentController?.page
            note("[\(name)] pinned: \(library.pinnedExtensions.map(\.name))")
            for ext in library.actionExtensions {
                let s = library.actionState(ext, for: page)
                note("[\(name)]   \(ext.name): label=\(s?.label ?? "-") badge=\(s?.badgeText ?? "-") unread=\(s?.hasUnreadBadge ?? false) enabled=\(s?.isEnabled ?? false) live=\(s?.hasSomethingForPage ?? false)")
            }
            note("[\(name)] ⌘K: \(browser.availableCommands().filter { $0.id.hasPrefix("ext:") }.map { $0.title + ($0.subtitle.map { " (\($0))" } ?? "") })")
            save(window, "pill-\(name)")
        }
        exit(0)
    }

    private func save(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    private func note(_ line: String) { FileHandle.standardError.write(Data("[pill] \(line)\n".utf8)) }
    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
