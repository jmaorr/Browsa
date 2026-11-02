#if os(iOS)
import Foundation
import WebKit
import ContentBlockerConverter

/// Ad, tracker and annoyance blocking with AdGuard's filter lists.
///
/// iOS only applies installed content blockers (AdGuard, 1Blocker…) to Safari, never to
/// WKWebView browsers, so the browser does the same job itself:
///
/// 1. The filter lists for each `FilterGroup` are downloaded from AdGuard (iOS-optimised builds),
///    at most every few days.
/// 2. AdGuard's SafariConverterLib turns them into WebKit content-blocking JSON, off the main
///    thread. That JSON is kept on disk.
/// 3. WebKit compiles each group into its own `WKContentRuleList` (each is capped at 150k rules,
///    which is why they're split, like AdGuard for iOS does). Compiled lists are cached by WebKit,
///    so later launches only look them up.
///
/// Sites the user switched blocking off for get one extra "ignore-previous-rules" rule at the end
/// of every list. Until the first download finishes, a small bundled starter list is used.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    private let store = WKContentRuleListStore.default()!
    private let directory = URL.applicationSupportDirectory.appending(path: "Filters", directoryHint: .isDirectory)
    private let refreshInterval: TimeInterval = 4 * 24 * 3600
    private let metadataKey = "duo.filters.metadata"

    struct Metadata: Codable {
        var lastUpdated: Date?
        var ruleCounts: [String: Int] = [:]
    }

    var metadata: Metadata {
        get {
            UserDefaults.standard.data(forKey: metadataKey)
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) } ?? Metadata()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: metadataKey) }
    }

    var needsUpdate: Bool {
        guard let last = metadata.lastUpdated else { return true }
        return Date().timeIntervalSince(last) > refreshInterval
    }

    // MARK: Lists to apply

    /// Compiled lists for the chosen groups, with `allowlist` hosts exempt. Falls back to the
    /// bundled starter list when nothing has been downloaded yet.
    func lists(for groups: Set<FilterGroup>, allowlist: Set<String>) async -> [WKContentRuleList] {
        var out: [WKContentRuleList] = []
        var wanted: Set<String> = []
        for group in FilterGroup.allCases where groups.contains(group) {
            guard let json = try? String(contentsOf: jsonURL(group), encoding: .utf8) else { continue }
            let id = identifier("filters.\(group.rawValue)", allowlist: allowlist)
            wanted.insert(id)
            if let list = await compiled(id: id, json: json, allowlist: allowlist) { out.append(list) }
        }
        if out.isEmpty, !groups.isEmpty,
           let url = Bundle.module.url(forResource: "blocklist", withExtension: "json"),
           let json = try? String(contentsOf: url, encoding: .utf8) {
            let id = identifier("starter", allowlist: allowlist)
            wanted.insert(id)
            if let list = await compiled(id: id, json: json, allowlist: allowlist) { out.append(list) }
        }
        await removeStale(keeping: wanted)
        return out
    }

    private func compiled(id: String, json: String, allowlist: Set<String>) async -> WKContentRuleList? {
        if let existing = try? await store.contentRuleList(forIdentifier: id) { return existing }
        do {
            return try await store.compileContentRuleList(forIdentifier: id,
                                                          encodedContentRuleList: Self.appendingAllowlist(allowlist, to: json))
        } catch {
            print("Content blocker \(id) failed to compile: \(error)")
            return nil
        }
    }

    /// Drops compiled lists from older filter versions or allowlists, so they don't pile up.
    private func removeStale(keeping wanted: Set<String>) async {
        guard let ids = await store.availableIdentifiers() else { return }
        for id in ids where id.hasPrefix("duo.") && !wanted.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    /// One identifier per filter version + allowlist, so a change means a fresh compile.
    private func identifier(_ name: String, allowlist: Set<String>) -> String {
        let version = metadata.lastUpdated.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        var hasher = StableHash()
        for host in allowlist.sorted() { hasher.combine(host) }
        return "duo.\(name).\(version).\(hasher.value)"
    }

    /// Adds a final rule that switches every earlier rule off on the allowlisted sites.
    nonisolated static func appendingAllowlist(_ hosts: Set<String>, to json: String) -> String {
        guard !hosts.isEmpty else { return json }
        let domains = hosts.sorted().map { "\"*\($0.lowercased())\"" }.joined(separator: ",")
        let rule = #"{"trigger":{"url-filter":".*","if-domain":[\#(domains)]},"action":{"type":"ignore-previous-rules"}}"#
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]") else { return json }
        let body = trimmed.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return body == "[" ? "[\(rule)]" : "\(body),\(rule)]"
    }

    private func jsonURL(_ group: FilterGroup) -> URL { directory.appending(path: "\(group.rawValue).json") }

    // MARK: Updating

    /// Downloads and converts every group's filters. Returns rule counts per group.
    func update(groups: Set<FilterGroup>) async throws -> [FilterGroup: Int] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var counts: [FilterGroup: Int] = [:]
        for group in FilterGroup.allCases where groups.contains(group) {
            var text = ""
            for url in group.urls {
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.cachePolicy = .reloadRevalidatingCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                text += String(decoding: data, as: UTF8.self) + "\n"
            }
            guard !text.isEmpty else { continue }
            let (json, count) = await Self.convert(text)
            try json.write(to: jsonURL(group), atomically: true, encoding: .utf8)
            counts[group] = count
        }
        var meta = metadata
        meta.lastUpdated = .now
        for (g, c) in counts { meta.ruleCounts[g.rawValue] = c }
        metadata = meta
        return counts
    }

    /// AdGuard syntax to WebKit JSON, on a background thread (a big list takes a few seconds).
    nonisolated static func convert(_ text: String) async -> (json: String, count: Int) {
        await Task.detached(priority: .utility) {
            var text = text
            text.makeContiguousUTF8()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let result = ContentBlockerConverter().convertArray(
                rules: lines,
                safariVersion: SafariVersion.autodetect(),
                advancedBlocking: false
            )
            return (result.safariRulesJSON, result.safariRulesCount)
        }.value
    }
}

/// FNV-1a, so identifiers stay the same across launches (Swift's Hasher is seeded per launch).
private struct StableHash {
    private(set) var value: UInt64 = 0xcbf29ce484222325
    mutating func combine(_ s: String) {
        for b in s.utf8 { value = (value ^ UInt64(b)) &* 0x100000001b3 }
        value = (value ^ 0x2c) &* 0x100000001b3
    }
}

extension WebViewPool {
    /// Every distinct content controller: the two shared configurations plus any popup's own.
    var allContentControllers: [WKUserContentController] {
        var seen = Set<ObjectIdentifier>()
        return ([configuration.userContentController, privateConfiguration.userContentController]
            + sessions.values.map { $0.webView.configuration.userContentController })
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Replaces the rule lists on new tabs and on every live web view.
    func setContentRuleLists(_ lists: [WKContentRuleList]) {
        for c in allContentControllers {
            c.removeAllContentRuleLists()
            lists.forEach(c.add)
        }
    }
}

/// Progress and results of the filter lists, for Settings.
public struct FilterStatus: Equatable, Sendable {
    public var isUpdating = false
    public var lastUpdated: Date?
    public var ruleCount = 0
    public var error: String?
}

extension BrowserState {
    /// Applies the current blocking settings: rule lists and the cookie-banner script. Downloads
    /// fresh filters in the background when they're due.
    func applyContentBlocking() {
        let s = settings
        pool.setAutoconsent(enabled: s.declineCookieBanners, skipping: s.blockingDisabledHosts, browser: self)
        blockingTask?.cancel()
        blockingTask = Task { @MainActor in
            let blocker = ContentBlocker.shared
            let lists = s.blockContent ? await blocker.lists(for: s.filterGroups, allowlist: s.blockingDisabledHosts) : []
            guard !Task.isCancelled else { return }
            pool.setContentRuleLists(lists)
            refreshFilterStatus()
            if s.blockContent, blocker.needsUpdate, !filterStatus.isUpdating { await updateFilters() }
        }
    }

    /// Downloads and recompiles the filter lists now.
    public func updateFilters() async {
        guard !filterStatus.isUpdating else { return }
        filterStatus.isUpdating = true
        filterStatus.error = nil
        do {
            _ = try await ContentBlocker.shared.update(groups: Set(FilterGroup.allCases))
        } catch {
            filterStatus.error = "Couldn't update filters. \(error.localizedDescription)"
        }
        filterStatus.isUpdating = false
        refreshFilterStatus()
        applyContentBlocking()
    }

    private func refreshFilterStatus() {
        let meta = ContentBlocker.shared.metadata
        filterStatus.lastUpdated = meta.lastUpdated
        filterStatus.ruleCount = settings.filterGroups.reduce(0) { $0 + (meta.ruleCounts[$1.rawValue] ?? 0) }
    }

    /// Page menu: switch ads, trackers and cookie-banner handling off (or back on) for this site.
    public func toggleBlockingForCurrentSite() {
        guard let tab = currentTab, let host = tab.url?.host()?.lowercased() else { return }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if settings.blockingDisabled(for: host) {
            settings.blockingDisabledHosts = settings.blockingDisabledHosts.filter { host != $0 && !host.hasSuffix("." + $0) }
            showToast("Blockers on for \(site)")
        } else {
            settings.blockingDisabledHosts.insert(site)
            showToast("Blockers off for \(site)")
        }
        // Reload once the new lists are in place.
        Task { @MainActor in
            await blockingTask?.value
            session(for: tab).webView.reload()
        }
    }

    public var blockingDisabledForCurrentSite: Bool {
        settings.blockingDisabled(for: currentTab?.url?.host())
    }
}
#endif
