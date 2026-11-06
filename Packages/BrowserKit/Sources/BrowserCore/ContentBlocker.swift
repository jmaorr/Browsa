#if canImport(WebKit)
import Foundation
import WebKit

/// Ad, tracker and annoyance blocking with AdGuard's filter lists.
///
/// iOS only applies installed content blockers (AdGuard, 1Blocker…) to Safari, never to
/// WKWebView browsers, so the browser does the same job itself:
///
/// 1. `tools/filter-rules` converts the lists into WebKit content-blocking JSON and publishes them.
///    That converter is GPL, so it stays out of this app, which only downloads what it produces.
/// 2. The JSON for each `FilterGroup` is downloaded from `rulesBaseURL`, at most every few days,
///    and kept on disk.
/// 3. WebKit compiles each group into its own `WKContentRuleList` (each is capped at 150k rules,
///    which is why they're split, like AdGuard for iOS does). Compiled lists are cached by WebKit,
///    so later launches only look them up.
///
/// Sites the user switched blocking off for get one extra "ignore-previous-rules" rule at the end
/// of every list. Until the first download finishes, a small bundled starter list is used.
@MainActor
public final class ContentBlocker {
    public static let shared = ContentBlocker()
    /// Where `tools/filter-rules` publishes. Change this if you host your own.
    public static let rulesBaseURL = URL(string: "https://rules.browsa.app/v1/")!

    private let store = WKContentRuleListStore.default()!
    private let directory = URL.applicationSupportDirectory.appending(path: "Filters", directoryHint: .isDirectory)
    private let refreshInterval: TimeInterval = 4 * 24 * 3600
    private let metadataKey = "duo.filters.metadata"

    public struct Metadata: Codable, Sendable {
        public var lastUpdated: Date?
        public var lastChecked: Date?
        /// The published rules' version, so an unchanged one isn't downloaded again.
        public var version: String?
        public var ruleCounts: [String: Int] = [:]
    }

    public internal(set) var metadata: Metadata {
        get {
            UserDefaults.standard.data(forKey: metadataKey)
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) } ?? Metadata()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: metadataKey) }
    }

    public var needsUpdate: Bool {
        // No rules at all means the last download was unusable, so don't wait out the interval.
        guard let last = metadata.lastChecked ?? metadata.lastUpdated, metadata.ruleCounts.values.contains(where: { $0 > 0 }) else { return true }
        return Date().timeIntervalSince(last) > refreshInterval
    }

    // MARK: Lists to apply

    /// Compiled lists for the chosen groups, with `allowlist` hosts exempt. Falls back to the
    /// bundled starter list when nothing has been downloaded yet.
    public func lists(for groups: Set<FilterGroup>, allowlist: Set<String>) async -> [WKContentRuleList] {
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

    private struct Manifest: Decodable {
        struct Group: Decodable {
            let file: String
            let rules: Int
        }
        let version: String
        let groups: [String: Group]
    }

    /// Downloads every group's rules if a newer version is published. Returns rule counts per group.
    public func update(groups: Set<FilterGroup>) async throws -> [FilterGroup: Int] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: await download("manifest.json"))
        let chosen = FilterGroup.allCases.filter(groups.contains)
        var meta = metadata
        meta.lastChecked = .now
        // A group switched on since the last update has no file yet, whatever the version says.
        let hasAll = chosen.allSatisfy { FileManager.default.fileExists(atPath: jsonURL($0).path()) }
        guard manifest.version != meta.version || !hasAll else {
            metadata = meta
            return [:]
        }
        var counts: [FilterGroup: Int] = [:]
        for group in chosen {
            guard let entry = manifest.groups[group.rawValue] else { continue }
            try await download(entry.file).write(to: jsonURL(group), options: .atomic)
            counts[group] = entry.rules
            meta.ruleCounts[group.rawValue] = entry.rules
        }
        meta.lastUpdated = .now
        meta.version = manifest.version
        metadata = meta
        return counts
    }

    private func download(_ file: String) async throws -> Data {
        var request = URLRequest(url: Self.rulesBaseURL.appending(path: file), timeoutInterval: 30)
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
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

/// Progress and results of the filter lists, for Settings.
public struct FilterStatus: Equatable, Sendable {
    public var isUpdating = false
    public var lastUpdated: Date?
    public var ruleCount = 0
    public var error: String?
    public init() {}
}

#if os(iOS)
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
        markContentRulesReady()
    }
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
#endif
