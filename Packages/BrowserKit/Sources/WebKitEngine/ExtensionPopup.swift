#if os(macOS)
import AppKit
import WebKit
import BrowserEngine

/// An extension's toolbar popup, in a popover of Browsa's own.
///
/// WebKit offers a popover of its own (`WKWebExtension.Action.popupPopover`), and it works for most
/// extensions, but for some the popup's messages never reach the extension's background and the
/// popup waits on a spinner for ever (Bitwarden), while the same page in a view built from the
/// extension's configuration talks to its background fine. So the page is loaded here, in such a
/// view. Sized as Chrome sizes a popup: to its content, 25 to 800 points wide and up to 600 tall.
/// `window.close()` closes it; windows it opens become tabs.
///
/// The approach is Search's (Office Commun, MIT, ExtensionPopup.swift).
@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    private var measuring: Timer?
    private var ticks = 0
    private weak var host: (any EngineExtensionHost)?
    private static var lastSize: [String: NSSize] = [:]
    private var extensionID = ""

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView, host: (any EngineExtensionHost)?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        self.host = host
        extensionID = context.uniqueIdentifier
        let size = Self.lastSize[extensionID] ?? NSSize(width: 360, height: 240)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.load(URLRequest(url: url))

        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(origin: .zero, size: size))
        controller.view.addSubview(web)
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.delegate = self
        self.web = web
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // Followed as it fills in (a list arriving from the background), for as long as it's open.
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        let closing = popover
        popover = nil
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        closing?.performClose(nil)
    }

    private func measure() {
        guard let web, let popover else { return }
        ticks += 1
        // Every quarter second for the first few seconds, then every second.
        if ticks > 20, ticks % 4 != 0 { return }
        web.evaluateJavaScript("[Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0), Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let pair = value as? [NSNumber], pair.count == 2, popover === self.popover else { return }
                let width = min(max(CGFloat(pair[0].doubleValue), 25), 800)
                let height = min(max(CGFloat(pair[1].doubleValue), 25), 600)
                let size = NSSize(width: width, height: height)
                guard abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 else { return }
                popover.contentSize = size
                Self.lastSize[self.extensionID] = size
            }
        }
    }

    // MARK: WKUIDelegate

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { _ = host?.openExtensionTab(url: url, windowID: nil, active: true) }
        return nil
    }

    // MARK: WKNavigationDelegate

    /// A link the popup follows to the web opens in a tab, as in Chrome, and the popup closes.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true,
              url.scheme == "http" || url.scheme == "https" else { return .allow }
        _ = host?.openExtensionTab(url: url, windowID: nil, active: true)
        close()
        return .cancel
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        measuring?.invalidate()
        measuring = nil
        popover = nil
        web = nil
    }
}
#endif
