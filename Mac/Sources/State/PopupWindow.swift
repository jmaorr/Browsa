import AppKit
import Observation
import BrowserCore
import BrowserEngine

/// A page asked for a sized window (`window.open` with a width or height): nearly always a sign-in
/// with Google, Apple, Microsoft or Okta. Like Safari and Chrome, it opens in a small window of its
/// own over its opener, so the tab list never changes. When the page closes itself (or you close the
/// window) the tab that opened it comes back to the front.
@MainActor
final class PopupWindow: NSObject, NSWindowDelegate, EnginePageDelegate {
    let page: any EnginePage
    let openerID: UUID
    private let isPrivate: Bool
    private weak var library: Library?
    private var window: NSWindow?
    private var didClose = false

    init(page: any EnginePage, opener: BrowserTab, library: Library, features: PopupFeatures, over parent: NSWindow?) {
        self.page = page
        self.openerID = opener.id
        self.isPrivate = opener.isPrivate
        self.library = library
        super.init()
        // After this returns, WebKit loads the request into the page; show the window on the next turn.
        DispatchQueue.main.async { [weak self] in self?.show(features: features, over: parent) }
    }

    private func show(features: PopupFeatures, over parent: NSWindow?) {
        guard !didClose else { return }
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // What the page asked for, kept to something sensible on this screen.
        let width = min(max(features.width ?? 500, 320), min(1200, visible.width - 40))
        let height = min(max(features.height ?? 640, 320), min(1000, visible.height - 40))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.tabbingMode = .disallowed
        w.contentView = page.view
        // Centred over the window it came from, a little above the middle, like Safari.
        let anchor = parent?.frame ?? visible
        var origin = NSPoint(x: anchor.midX - width / 2, y: anchor.midY - height / 2 + 40)
        origin.x = min(max(origin.x, visible.minX + 20), visible.maxX - width - 20)
        origin.y = min(max(origin.y, visible.minY + 20), visible.maxY - height - 20)
        w.setFrameOrigin(origin)
        window = w
        updateTitle()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(page.view)
    }

    /// The page's title, with the site underneath so you can see who's asking you to sign in.
    private func updateTitle() {
        guard let window, !didClose else { return }
        withObservationTracking {
            let title = page.state.title
            window.title = title.isEmpty ? "Loading…" : title
            window.subtitle = page.state.url?.host() ?? ""
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }
    }

    private var opener: BrowserTab? { library?.tab(id: openerID) }

    func close() {
        guard !didClose else { return }
        if let window { window.close() } else { finish() }
    }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        page.close()
        library?.popupWindowClosed(self)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) { finish() }

    // MARK: EnginePageDelegate

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard request.wantsNewTab else { return .allow }
        if let library, let opener { library.openInNewTab(request.url, from: opener, foreground: request.wantsForeground) }
        else { library?.activeWindow?.newTab(url: request.url, isPrivate: isPrivate, source: .link) }
        return .cancel
    }

    /// A popup of a popup becomes a tab next to the original opener.
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? {
        guard let library, let opener else { return nil }
        return library.openPopup(from: opener, page: popup, url: url)
    }

    func pageDidRequestClose(_ page: any EnginePage) { close() }

    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse {
        guard let window else { return .cancel }
        let alert = NSAlert()
        var field: NSTextField?
        switch dialog {
        case .alert(let host, let message):
            alert.messageText = host
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        case .confirm(let host, let message):
            alert.messageText = host
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        case .prompt(let host, let message, let defaultText):
            alert.messageText = host
            alert.informativeText = message
            let f = NSTextField(string: defaultText)
            f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = f
            field = f
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        case .credentials:
            return .cancel
        }
        let answer = await alert.beginSheetModal(for: window)
        guard answer == .alertFirstButtonReturn else { return .cancel }
        if let field { return .text(field.stringValue) }
        return .ok
    }

    func page(_ page: any EnginePage, didStartDownload download: EngineDownload) {
        guard let library else { return }
        library.add(download, from: nil)
    }
}
