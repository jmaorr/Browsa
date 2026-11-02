#if os(iOS)
import Foundation
import WebKit

/// A page reduced to its article by Mozilla's Readability (Apache-2.0, the engine behind
/// Firefox's Reader View).
public struct ReaderArticle: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let url: URL
    public let title: String
    public let byline: String?
    public let siteName: String?
    /// Cleaned article HTML. Readability strips scripts and handlers, and Reader shows it with
    /// JavaScript off.
    public let html: String
}

extension BrowserState {
    /// Runs Readability on the current page in an isolated world and opens Reader, or says why not.
    public func showReader() {
        guard let tab = currentTab, let url = tab.url else { return }
        let webView = session(for: tab).webView
        Task { @MainActor in
            guard let source = Self.readabilitySource else { return }
            let body = source + """

            var a = new Readability(document.cloneNode(true), { charThreshold: 400 }).parse();
            return a && a.length > 400 ? { title: a.title || "", byline: a.byline || "", site: a.siteName || "", content: a.content } : null;
            """
            let raw = try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil,
                                                             contentWorld: .world(name: "duo.reader"))
            guard let dict = raw as? [String: Any], let html = dict["content"] as? String else {
                showToast("Reader isn't available for this page")
                return
            }
            func text(_ key: String) -> String? { (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            readerArticle = ReaderArticle(url: url, title: text("title") ?? tab.displayTitle,
                                          byline: text("byline"), siteName: text("site"), html: html)
        }
    }

    private static let readabilitySource: String? = Bundle.module.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}
#endif
