import SwiftUI
import WebKit
import BrowserCore
import Suggest

/// Reader: the article on its own, in the system font, following light/dark mode and Dynamic
/// Type. Shown in a web view with JavaScript off, so nothing from the page can run here.
struct ReaderView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let article: ReaderArticle
    @AppStorage("reader.textScale") private var textScale = 1.0
    /// Reader fills the screen instead of sitting in a sheet. Remembered for next time.
    @AppStorage(ReaderView.fullScreenKey) private var fullScreen = false
    static let fullScreenKey = "reader.fullScreen"

    var body: some View {
        NavigationStack {
            ReaderWebView(article: article, scale: textScale)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(article.siteName ?? URLNormalizer.displayHost(article.url))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(fullScreen ? "Exit Full Screen" : "Full Screen",
                               systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                            fullScreen.toggle()
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Smaller Text", systemImage: "textformat.size.smaller") {
                            textScale = max(0.7, (textScale * 10 - 1).rounded() / 10)
                        }
                        .disabled(textScale <= 0.7)
                        Button("Larger Text", systemImage: "textformat.size.larger") {
                            textScale = min(2.0, (textScale * 10 + 1).rounded() / 10)
                        }
                        .disabled(textScale >= 2.0)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func page(for a: ReaderArticle, scale: Double) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; font-size: \(Int((scale * 100).rounded()))%; }
          body { font: -apple-system-body; font-size: 1.12rem; line-height: 1.55; margin: 0 auto; padding: 18px 20px 60px;
                 max-width: 38em; color: CanvasText; background: Canvas; -webkit-text-size-adjust: none; }
          h1 { font: -apple-system-title1; font-size: 1.9rem; font-weight: 700; line-height: 1.2; margin: 8px 0 6px; }
          .byline { color: GrayText; font: -apple-system-subheadline; font-size: .95rem; margin-bottom: 22px; }
          img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
          figure { margin: 18px 0; } figcaption { color: GrayText; font: -apple-system-footnote; font-size: .85rem; margin-top: 6px; }
          a { color: -apple-system-blue; text-decoration: none; }
          pre, code { font-family: ui-monospace, monospace; font-size: .9em; }
          pre { overflow-x: auto; padding: 12px; border-radius: 8px; background: color-mix(in srgb, CanvasText 6%, Canvas); }
          blockquote { margin: 16px 0; padding-left: 14px; border-left: 3px solid color-mix(in srgb, CanvasText 20%, Canvas); color: GrayText; }
          table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; }
          td, th { border: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); padding: 4px 8px; }
        </style></head><body>
        <h1>\(escape(a.title))</h1>
        \(a.byline.map { "<div class=\"byline\">\(escape($0))</div>" } ?? "")
        \(a.html)
        </body></html>
        """
    }
}

/// A plain web view for Reader: no JavaScript, links open in the browser.
///
/// Text size is set in the page's CSS, so a larger size rewraps the lines to the sheet's width.
/// (Zooming the web view scaled the whole page instead and pushed it off the sheet's edges.)
/// Changing it reloads the page and keeps your place.
private struct ReaderWebView: UIViewRepresentable {
    let article: ReaderArticle
    let scale: Double
    @Environment(BrowserState.self) private var browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        context.coordinator.loadedScale = scale
        wv.loadHTMLString(ReaderView.page(for: article, scale: scale), baseURL: article.url)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        guard c.loadedScale != scale else { return }
        c.loadedScale = scale
        // Where you were, as a fraction of the article, so the reflowed page opens at the same spot.
        let sv = wv.scrollView
        let range = sv.contentSize.height - sv.bounds.height
        c.pendingScrollFraction = range > 0 ? max(0, sv.contentOffset.y) / range : 0
        wv.loadHTMLString(ReaderView.page(for: article, scale: scale), baseURL: article.url)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var browser: BrowserState?
        var loadedScale: Double = 1
        var pendingScrollFraction: Double?
        init(browser: BrowserState) { self.browser = browser }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The article itself loads; a tapped link closes Reader and opens in the tab.
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            browser?.readerArticle = nil
            browser?.perform(.open(url), source: .link)
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let fraction = pendingScrollFraction else { return }
            pendingScrollFraction = nil
            let sv = webView.scrollView
            let range = sv.contentSize.height - sv.bounds.height
            if range > 0 { sv.setContentOffset(CGPoint(x: 0, y: range * fraction), animated: false) }
        }
    }
}
