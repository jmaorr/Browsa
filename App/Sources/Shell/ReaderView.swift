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

    var body: some View {
        NavigationStack {
            ReaderWebView(html: Self.page(for: article), baseURL: article.url, scale: textScale)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(article.siteName ?? URLNormalizer.displayHost(article.url))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ShareLink(item: article.url)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Smaller Text", systemImage: "textformat.size.smaller") {
                            textScale = max(0.7, textScale - 0.1)
                        }
                        .disabled(textScale <= 0.7)
                        Button("Larger Text", systemImage: "textformat.size.larger") {
                            textScale = min(2.0, textScale + 0.1)
                        }
                        .disabled(textScale >= 2.0)
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func page(for a: ReaderArticle) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body; font-size: 1.12em; line-height: 1.55; margin: 0 auto; padding: 18px 20px 60px;
                 max-width: 38em; color: CanvasText; background: Canvas; -webkit-text-size-adjust: none; }
          h1 { font: -apple-system-title1; font-weight: 700; line-height: 1.2; margin: 8px 0 6px; }
          .byline { color: GrayText; font: -apple-system-subheadline; margin-bottom: 22px; }
          img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
          figure { margin: 18px 0; } figcaption { color: GrayText; font: -apple-system-footnote; margin-top: 6px; }
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
private struct ReaderWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
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
        wv.pageZoom = scale
        wv.loadHTMLString(html, baseURL: baseURL)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if wv.pageZoom != scale { wv.pageZoom = scale }
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var browser: BrowserState?
        init(browser: BrowserState) { self.browser = browser }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The article itself loads; a tapped link closes Reader and opens in the tab.
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            browser?.readerArticle = nil
            browser?.perform(.open(url), source: .link)
            return .cancel
        }
    }
}
