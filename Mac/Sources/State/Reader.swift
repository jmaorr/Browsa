import AppKit
import BrowserCore
import BrowserEngine
import Suggest

/// Reader for one tab: the article Readability found, shown in its own page with JavaScript off.
/// A link in the article closes Reader and opens in the tab.
@MainActor
final class ReaderSession: EnginePageDelegate {
    let tabID: UUID
    let article: ReaderArticle
    private(set) var page: (any EnginePage)!
    private weak var browser: Browser?

    init(article: ReaderArticle, tabID: UUID, browser: Browser) {
        self.article = article
        self.tabID = tabID
        self.browser = browser
        page = browser.engine.makePage(options: PageOptions(profile: .ephemeral, allowsJavaScript: false), delegate: self)
        page.zoom = Preferences.readerScale
        page.loadHTML(Self.html(for: article), baseURL: article.url)
    }

    /// Text size. The engine's page zoom reflows the text to the column, so lines stay readable.
    func zoom(by direction: Int) {
        let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]
        let current = page.zoom
        let next = direction == 0 ? 1
            : direction > 0 ? (steps.first { $0 > current + 0.001 } ?? steps.last!)
            : (steps.last { $0 < current - 0.001 } ?? steps.first!)
        page.zoom = next
        Preferences.readerScale = next
    }

    func close() { page.close() }

    // MARK: EnginePageDelegate

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        // The article itself loads; anything clicked leaves Reader.
        guard request.kind == .link || request.wantsNewTab, let browser else { return .allow }
        if request.wantsNewTab, let tab = browser.currentTab {
            browser.library.openInNewTab(request.url, from: tab, foreground: request.wantsForeground)
        } else {
            browser.closeReader()
            browser.navigate(to: request.url, replacing: true, source: .link)
        }
        return .cancel
    }

    // MARK: Page

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(for a: ReaderArticle) -> String {
        let meta = [a.byline, a.siteName].compactMap { $0 }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; }
          body { font: 19px/1.6 "New York", ui-serif, Georgia, serif; margin: 0 auto; padding: 56px 32px 96px;
                 max-width: 40em; color: CanvasText; background: Canvas; }
          h1 { font: 700 2.1em/1.18 ui-serif, "New York", Georgia, serif; margin: 0 0 10px; letter-spacing: -0.01em; }
          .meta { color: GrayText; font: 15px/1.4 -apple-system, system-ui, sans-serif; margin-bottom: 30px; }
          h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.3; margin: 1.6em 0 0.5em; }
          img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
          figure { margin: 26px 0; }
          figcaption { color: GrayText; font: 14px/1.4 -apple-system, system-ui, sans-serif; margin-top: 8px; }
          a { color: LinkText; text-decoration: none; }
          a:hover { text-decoration: underline; }
          pre, code { font-family: ui-monospace, monospace; font-size: .85em; }
          pre { overflow-x: auto; padding: 14px; border-radius: 8px; background: color-mix(in srgb, CanvasText 6%, Canvas); }
          blockquote { margin: 20px 0; padding-left: 16px; border-left: 3px solid color-mix(in srgb, CanvasText 20%, Canvas); color: GrayText; }
          table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; font-size: .9em; }
          td, th { border: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); padding: 4px 8px; }
          hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); margin: 32px 0; }
        </style></head><body>
        <h1>\(escape(a.title))</h1>
        \(meta.isEmpty ? "" : "<div class=\"meta\">\(meta)</div>")
        \(a.html)
        </body></html>
        """
    }
}

extension Browser {
    var isReaderShowing: Bool { reader != nil && reader?.tabID == currentTab?.id }

    /// Shift-Cmd-R: Reader on, or off again.
    func toggleReader() {
        if reader != nil { closeReader(); return }
        guard let tab = currentTab, let url = tab.url, let script = ReaderArticle.extractionScript else { return }
        let page = controller(for: tab).page!
        Task { @MainActor in
            let raw = try? await page.evaluate(script, inWorld: "browsa.reader")
            guard currentTab?.id == tab.id else { return }
            guard let article = ReaderArticle(extraction: raw, url: url, fallbackTitle: tab.displayTitle) else {
                showToast("Reader isn't available for this page")
                return
            }
            find = nil
            reader = ReaderSession(article: article, tabID: tab.id, browser: self)
        }
    }

    func closeReader() {
        reader?.close()
        reader = nil
    }
}
