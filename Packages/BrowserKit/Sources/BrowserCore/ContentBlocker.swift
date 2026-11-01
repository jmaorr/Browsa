#if os(iOS)
import Foundation
import WebKit

/// Compiles the bundled tracker/ad block list into a WKContentRuleList once, then caches it.
/// WebKit stores compiled lists on disk, so later launches just look the list up.
///
/// The bundled list is a starter of ~80 ad/tracker domains (third-party loads only). To use
/// EasyList/EasyPrivacy, convert them with AdGuard's SafariConverterLib and replace
/// Resources/blocklist.json. Content rule lists are capped at 150k rules each.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    private let identifier = "duo.blocklist.v1"
    private var cached: WKContentRuleList?

    func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        let store = WKContentRuleListStore.default()!
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) {
            cached = existing
            return existing
        }
        guard let url = Bundle.module.url(forResource: "blocklist", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            cached = list
            return list
        } catch {
            print("Content blocker failed to compile: \(error)")
            return nil
        }
    }
}

extension WebViewPool {
    /// Adds or removes the rule list on the shared configurations (new tabs) and on every live web view.
    func setContentRuleList(_ list: WKContentRuleList?) {
        let controllers = [configuration.userContentController, privateConfiguration.userContentController]
            + sessions.values.map { $0.webView.configuration.userContentController }
        for c in controllers {
            c.removeAllContentRuleLists()
            if let list { c.add(list) }
        }
    }
}

extension BrowserState {
    func applyContentBlocking() {
        let enabled = settings.blockContent
        Task { @MainActor in
            let list = enabled ? await ContentBlocker.shared.ruleList() : nil
            pool.setContentRuleList(list)
        }
    }
}
#endif
