import Foundation
import Suggest

/// Visit history with incremental frecency. Persists to a JSON file in Application Support.
///
/// v0 keeps everything in memory, which is fine up to tens of thousands of URLs. When that stops
/// being true, swap the storage for GRDB + FTS5 behind the same `HistoryIndex` API (see the plan).
public actor HistoryStore: HistoryIndex {
    struct Record: Codable {
        var url: URL
        var title: String
        var frecency: Double
        var lastUpdate: Date
        var visitCount: Int
        var isBookmark: Bool
    }

    private var records: [String: Record] = [:]
    private let fileURL: URL?
    private let frecency = Frecency()
    private var saveTask: Task<Void, Never>?

    /// - Parameter fileURL: nil keeps history in memory only (private mode, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    public static func defaultFileURL() -> URL {
        let dir = AppFolders.support.appending(path: "Browser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }

    // MARK: Writing

    public func recordVisit(url: URL, title: String, source: Frecency.VisitSource, at now: Date = .now) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = URLNormalizer.key(for: url)
        var r = records[key] ?? Record(url: url, title: title, frecency: 0, lastUpdate: now,
                                       visitCount: 0, isBookmark: false)
        r.frecency = frecency.adding(source, to: r.frecency, lastUpdate: r.lastUpdate, now: now)
        r.lastUpdate = now
        r.visitCount += 1
        r.url = url
        if !title.isEmpty { r.title = title }
        records[key] = r
        scheduleSave()
    }

    public func updateTitle(url: URL, title: String) {
        let key = URLNormalizer.key(for: url)
        guard !title.isEmpty, records[key] != nil else { return }
        records[key]?.title = title
        scheduleSave()
    }

    public func setBookmarked(_ url: URL, _ value: Bool) {
        let key = URLNormalizer.key(for: url)
        if records[key] == nil {
            records[key] = Record(url: url, title: "", frecency: 0, lastUpdate: .now, visitCount: 0, isBookmark: value)
        } else {
            records[key]?.isBookmark = value
        }
        scheduleSave()
    }

    /// A page from another browser's history or bookmarks, for `importVisits`.
    public struct ImportedVisit: Sendable {
        public var url: URL
        public var title: String
        public var visitCount: Int
        public var lastVisit: Date
        public var isBookmark: Bool
        public init(url: URL, title: String, visitCount: Int, lastVisit: Date, isBookmark: Bool) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.lastVisit = lastVisit
            self.isBookmark = isBookmark
        }
    }

    /// Brings in another browser's history and bookmarks. An imported page starts with a damped
    /// score from its visit count, dated to its last visit, so it suggests well without crowding
    /// out what's visited here. Returns how many pages were new.
    @discardableResult
    public func importVisits(_ items: [ImportedVisit]) -> Int {
        var added = 0
        for item in items {
            guard let scheme = item.url.scheme, scheme == "http" || scheme == "https" else { continue }
            let key = URLNormalizer.key(for: item.url)
            let score = (item.isBookmark ? 1.6 : 0) + min(Double(item.visitCount), 30) * 0.6
            if var r = records[key] {
                r.frecency += frecency.decayed(score, from: item.lastVisit, to: r.lastUpdate)
                r.visitCount += item.visitCount
                r.isBookmark = r.isBookmark || item.isBookmark
                if r.title.isEmpty { r.title = item.title }
                records[key] = r
            } else {
                records[key] = Record(url: item.url, title: item.title, frecency: score, lastUpdate: item.lastVisit,
                                      visitCount: item.visitCount, isBookmark: item.isBookmark)
                added += 1
            }
        }
        scheduleSave()
        return added
    }

    public func clearAll() {
        records.removeAll()
        scheduleSave()
    }

    // MARK: HistoryIndex

    public func candidates(matching query: String, limit: Int) async -> [HistoryEntry] {
        let now = Date.now
        let f = frecency
        return records.values
            .filter { Matcher.quality(query: query, url: $0.url, title: $0.title) != .none }
            .map { HistoryEntry(url: $0.url, title: $0.title,
                                frecency: f.decayed($0.frecency, from: $0.lastUpdate, to: now),
                                isBookmark: $0.isBookmark) }
            .sorted { $0.frecency > $1.frecency }
            .prefix(limit).map { $0 }
    }

    public func topSites(limit: Int) async -> [HistoryEntry] {
        let now = Date.now
        // Top sites are per host: collapse github.com/a and github.com/b into github.com.
        var byHost: [String: HistoryEntry] = [:]
        for r in records.values {
            guard let host = r.url.host() else { continue }
            let score = frecency.decayed(r.frecency, from: r.lastUpdate, to: now)
            let hostKey = URLNormalizer.displayHost(r.url)
            let existing = byHost[hostKey]?.frecency ?? 0
            var root = URLComponents()
            root.scheme = r.url.scheme
            root.host = host
            byHost[hostKey] = HistoryEntry(url: root.url ?? r.url,
                                           title: existing > 0 ? (byHost[hostKey]?.title ?? "") : r.title,
                                           frecency: existing + score)
        }
        return byHost.values.sorted { $0.frecency > $1.frecency }.prefix(limit).map { $0 }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    public func saveNow() {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
