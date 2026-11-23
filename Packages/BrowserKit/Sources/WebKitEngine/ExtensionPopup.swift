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

    /// The popup as WebKit knows it: a tab-like page of the window in front (Chrome gives a popup no
    /// tab, but WebKit routes a page's messages through one).
    private var tab: PopupTab?
    private weak var extensions: WebKitExtensions?

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView, host: (any EngineExtensionHost)?,
              extensions: WebKitExtensions?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        self.host = host
        self.extensions = extensions
        extensionID = context.uniqueIdentifier
        let size = Self.lastSize[extensionID] ?? NSSize(width: 360, height: 240)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.load(URLRequest(url: url))

        // The page is the popover's whole content, so it always fills it; opaque white behind it,
        // as Chrome paints a popup, rather than the popover's translucent material.
        web.underPageBackgroundColor = .white
        let controller = NSViewController()
        controller.view = web
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.delegate = self
        self.web = web
        self.popover = popover
        let tab = PopupTab(web: web, window: extensions?.frontWindow())
        self.tab = tab
        extensions?.controller.didOpenTab(tab)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // Followed as it fills in (a list arriving from the background), for as long as it's open.
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        forgetTab()
        let closing = popover
        popover = nil
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        closing?.performClose(nil)
    }

    /// The size Chrome would give the page: its own width (or its narrowest), and its height laid out
    /// at that width, within 25-800 x 25-600. Search's measure (Office Commun, MIT, ExtensionPopup.swift).
    static let preferred = """
    () => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      const m = window.__browsaSizing || (window.__browsaSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      // The overflow the view takes: the root's, or the body's handed up.
      const root = getComputedStyle(d), body = document.body && getComputedStyle(document.body);
      const view = root.overflowX === "visible" && root.overflowY === "visible" && body ? body : root;
      const bar = innerWidth - v.clientWidth, barAcross = innerHeight - v.clientHeight;
      const across = view.overflowX === "scroll" ? barAcross : 0;
      let gutter = view.overflowY === "scroll" ? bar : 0;
      const box = d.getBoundingClientRect();
      // A width the page sets for itself shows as one the view doesn't
      // have, excluding its scrollbar; one equal to the view is either
      // filling it or the width it was given last time, remembered.
      let w;
      if (Math.abs(box.width - v.clientWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - v.clientWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      let width;
      const lay = () => {
        back();
        width = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
        d.style.setProperty("width", (width - gutter) + "px", "important");
        let h = d.getBoundingClientRect().height;
        if (Math.abs(h - innerHeight) > 1) m.h = h;
        else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
        else {
          d.style.setProperty("height", "auto", "important");
          d.style.setProperty("min-height", "0", "important");
          h = d.getBoundingClientRect().height;
        }
        return h;
      };
      let h = lay();
      // Taller than the popup: it scrolls, and a scroll bar shown always
      // takes its room across.
      if (gutter !== bar && h + across > 600) { gutter = bar; h = lay(); }
      back();
      return [width, Math.min(600, Math.max(25, Math.ceil(h + across)))];
    }
    """

    private func measure() {
        guard let web, let popover else { return }
        ticks += 1
        // Every quarter second: for its first two seconds the popup follows the page either way, then
        // only grows, so a page that settles doesn't set it rocking; after six seconds, once a second.
        if ticks > 24, ticks % 4 != 0 { return }
        let either = ticks <= 8
        web.evaluateJavaScript("(\(Self.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, popover === self.popover, let pair = value as? [Double], pair.count == 2 else { return }
                let now = popover.contentSize
                let wanted = either ? NSSize(width: pair[0], height: pair[1])
                    : NSSize(width: max(now.width, pair[0]), height: max(now.height, pair[1]))
                self.apply(wanted)
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        guard abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 else { return }
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
        Self.lastSize[extensionID] = size
    }

    /// The document is built: the moment Chrome sizes a popup, before the page's scripts look at the
    /// room they have (WebKit tells a navigation delegate that has this method).
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        ticks = 0
        measure()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        measure()
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
        forgetTab()
        popover = nil
        web = nil
    }

    private func forgetTab() {
        if let tab { extensions?.controller.didCloseTab(tab, windowIsClosing: false) }
        tab = nil
    }

    #if DEBUG
    /// The popover's window, for the compat harness's pictures.
    var debugWindow: NSWindow? { popover?.contentViewController?.view.window }
    #endif
}

/// The popup as a tab for WebKit's extension messaging (Search's PopupPage).
@available(macOS 15.4, *)
@MainActor
final class PopupTab: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    let owner: ExtensionWindow?

    init(web: WKWebView, window: ExtensionWindow?) {
        self.web = web
        self.owner = window
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}
#endif
