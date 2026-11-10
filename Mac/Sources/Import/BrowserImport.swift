import Foundation
import AppKit
import SQLite3
import BrowserCore
import Suggest

// Bringing someone's things over from the browser they're leaving: bookmarks, history, and from
// Arc its spaces with their pinned and open tabs. Everything is read straight from the other
// browser's files on this Mac, and only ever read. Passwords are never touched.

/// A browser on this Mac that can be imported from.
struct ImportSource: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Chrome, Edge, Vivaldi, Brave and Arc keep Chromium's profile layout under this folder.
        case chromium(dataDir: URL)
        case safari
    }

    struct Profile: Identifiable, Hashable, Sendable {
        let folder: String
        let name: String
        var id: String { folder }
    }

    let id: String
    let name: String
    let kind: Kind
    let profiles: [Profile]
    /// Arc keeps its spaces, pinned tabs and open tabs in its own sidebar file.
    var isArc: Bool { id == "arc" }
    var isSafari: Bool { kind == .safari }
}

/// How the import lands. The card imports with the defaults; Configure changes them.
struct ImportOptions: Hashable, Sendable {
    enum Bookmarks: String, CaseIterable, Hashable, Sendable {
        case searchAndFavourites, searchOnly, skip
        var label: String {
            switch self {
            case .searchAndFavourites: "Find them with ⌘T, and pin the top few as Favourites"
            case .searchOnly: "Just find them with ⌘T"
            case .skip: "Don't import bookmarks"
            }
        }
    }

    enum HistoryRange: String, CaseIterable, Hashable, Sendable {
        case threeMonths, year, all
        var label: String {
            switch self {
            case .threeMonths: "Last 3 months"
            case .year: "Last year"
            case .all: "Everything"
            }
        }
        var since: Date? {
            switch self {
            case .threeMonths: Calendar.current.date(byAdding: .month, value: -3, to: .now)
            case .year: Calendar.current.date(byAdding: .year, value: -1, to: .now)
            case .all: nil
            }
        }
    }

    var profile: String?
    var importBookmarks = true
    var bookmarkMode: Bookmarks = .searchAndFavourites
    var bookmarks: Bookmarks { importBookmarks ? bookmarkMode : .skip }
    var favouriteCount = 8
    var history = true
    var historyRange: HistoryRange = .threeMonths
    /// Arc only: its spaces become Browsa spaces, with their pinned and open tabs.
    var arcSpaces = true
    /// Arc only: the spaces left out, by Arc's id. Empty brings them all.
    var skippedSpaces: Set<String> = []

    func includes(_ spaceID: String) -> Bool { !skippedSpaces.contains(spaceID) }

    mutating func set(_ spaceID: String, included: Bool, all: [String]) {
        if included { skippedSpaces.remove(spaceID) } else { skippedSpaces.insert(spaceID) }
        // Leaving every space out is the same as turning Spaces off.
        if Set(all).isSubset(of: skippedSpaces) { arcSpaces = false; skippedSpaces = [] }
    }
}

/// What came over, for the card's counts.
struct ImportResult: Equatable, Sendable {
    var bookmarks = 0
    var favourites = 0
    var history = 0
    var spaces = 0
    var tabs = 0
}

/// What was read, before it lands in Browsa.
struct ImportedData: Sendable {
    struct Space: Sendable {
        /// The other browser's own id for the space, so importing again doesn't duplicate it.
        var sourceID: String
        var name: String
        var pinned: [(title: String, url: URL)]
        var open: [(title: String, url: URL)]
    }

    var bookmarks: [(title: String, url: URL)] = []
    /// The bookmarks bar, or Arc's top apps: the best candidates for Favourites.
    var bar: [(title: String, url: URL)] = []
    var history: [HistoryStore.ImportedVisit] = []
    var spaces: [Space] = []
}

enum ImportError: LocalizedError {
    case needsFullDiskAccess
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess: "Browsa needs Full Disk Access to read Safari's bookmarks and history."
        case .unreadable(let what): "Couldn't read \(what)."
        }
    }
}

enum BrowserImport {
    private static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support") }
    static var safariFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari") }

    // MARK: Finding browsers

    /// The browsers on this Mac with something to import, Arc and Chrome first.
    static func detect() -> [ImportSource] {
        let chromium: [(id: String, name: String, path: String)] = [
            ("arc", "Arc", "Arc/User Data"),
            ("chrome", "Chrome", "Google/Chrome"),
            ("edge", "Edge", "Microsoft Edge"),
            ("brave", "Brave", "BraveSoftware/Brave-Browser"),
            ("vivaldi", "Vivaldi", "Vivaldi"),
        ]
        var found: [ImportSource] = chromium.compactMap { b in
            let dir = support.appending(path: b.path, directoryHint: .isDirectory)
            let profiles = chromiumProfiles(in: dir)
            guard !profiles.isEmpty else { return nil }
            return ImportSource(id: b.id, name: b.name, kind: .chromium(dataDir: dir), profiles: profiles)
        }
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") || FileManager.default.fileExists(atPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app") {
            found.append(ImportSource(id: "safari", name: "Safari", kind: .safari, profiles: []))
        }
        return found
    }

    /// Profiles from Chromium's Local State, falling back to the folders that hold bookmarks or history.
    private static func chromiumProfiles(in dir: URL) -> [ImportSource.Profile] {
        let fm = FileManager.default
        var profiles: [ImportSource.Profile] = []
        if let data = try? Data(contentsOf: dir.appending(path: "Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            profiles = cache.compactMap { folder, value in
                let name = (value as? [String: Any])?["name"] as? String ?? folder
                return ImportSource.Profile(folder: folder, name: name)
            }
        }
        if profiles.isEmpty, fm.fileExists(atPath: dir.appending(path: "Default").path) {
            profiles = [.init(folder: "Default", name: "Default")]
        }
        return profiles
            .filter { p in ["Bookmarks", "History"].contains { fm.fileExists(atPath: dir.appending(path: p.folder).appending(path: $0).path) } }
            .sorted { $0.folder == "Default" ? true : $1.folder == "Default" ? false : $0.name < $1.name }
    }

    /// Whether Browsa can read Safari's files yet; false until Full Disk Access is granted.
    static var canReadSafari: Bool {
        FileManager.default.isReadableFile(atPath: safariFolder.appending(path: "Bookmarks.plist").path)
            && (try? Data(contentsOf: safariFolder.appending(path: "Bookmarks.plist"), options: .mappedIfSafe)) != nil
    }

    /// System Settings, at Privacy & Security › Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading

    /// Reads everything the options ask for. Off the main thread: history can be large.
    static func read(_ source: ImportSource, options: ImportOptions) async throws -> ImportedData {
        try await Task.detached(priority: .userInitiated) {
            var out = ImportedData()
            switch source.kind {
            case .chromium(let dir):
                let folder = options.profile ?? source.profiles.first?.folder ?? "Default"
                let profile = dir.appending(path: folder, directoryHint: .isDirectory)
                if options.bookmarks != .skip {
                    (out.bookmarks, out.bar) = chromiumBookmarks(profile.appending(path: "Bookmarks"))
                }
                if options.history {
                    out.history = try chromiumHistory(profile.appending(path: "History"), since: options.historyRange.since)
                }
                if source.isArc {
                    let arc = arcSidebar()
                    if options.arcSpaces { out.spaces = arc.spaces }
                    // Arc's bookmarks live in its sidebar, not a Bookmarks file: its pinned tabs
                    // and top apps are the closest thing.
                    if options.bookmarks != .skip {
                        let pinned = arc.spaces.flatMap(\.pinned)
                        out.bookmarks += arc.topApps + pinned
                        if out.bar.isEmpty { out.bar = arc.topApps }
                    }
                }
            case .safari:
                guard canReadSafari else { throw ImportError.needsFullDiskAccess }
                if options.bookmarks != .skip {
                    (out.bookmarks, out.bar) = safariBookmarks(safariFolder.appending(path: "Bookmarks.plist"))
                }
                if options.history {
                    out.history = try safariHistory(safariFolder.appending(path: "History.db"), since: options.historyRange.since)
                }
            }
            return out
        }.value
    }

    // MARK: Chromium

    private static func chromiumBookmarks(_ file: URL) -> ([(title: String, url: URL)], [(title: String, url: URL)]) {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return ([], []) }
        func walk(_ node: [String: Any], into list: inout [(title: String, url: URL)]) {
            if node["type"] as? String == "url", let s = node["url"] as? String, let url = URL(string: s) {
                list.append((node["name"] as? String ?? "", url))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, into: &list) }
        }
        var all: [(title: String, url: URL)] = []
        var bar: [(title: String, url: URL)] = []
        if let b = roots["bookmark_bar"] as? [String: Any] {
            // The bar's own top-level links, in order, are the Favourites candidates.
            bar = (b["children"] as? [[String: Any]] ?? []).compactMap { c in
                guard c["type"] as? String == "url", let s = c["url"] as? String, let url = URL(string: s) else { return nil }
                return (c["name"] as? String ?? "", url)
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { walk(node, into: &all) }
        }
        return (all, bar)
    }

    /// Chromium keeps visit times in microseconds since 1601.
    private static func chromiumDate(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    private static func chromiumHistory(_ file: URL, since: Date?) throws -> [HistoryStore.ImportedVisit] {
        let sinceMicros = since.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0
        return try query(file, sql: """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND last_visit_time > \(sinceMicros)
            ORDER BY visit_count DESC LIMIT 25000
            """) { row in
            guard let url = URL(string: row.text(0)) else { return nil }
            return .init(url: url, title: row.text(1), visitCount: Int(row.int(2)), lastVisit: chromiumDate(row.int(3)), isBookmark: false)
        }
    }

    // MARK: Arc

    /// Arc's spaces with their pinned and unpinned tabs, and its top apps, from StorableSidebar.json.
    /// Folders are flattened: their tabs keep their order.
    static func arcSidebar() -> (spaces: [ImportedData.Space], topApps: [(title: String, url: URL)]) {
        let file = support.appending(path: "Arc/StorableSidebar.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (json["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else { return ([], []) }
        let items = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let byID = Dictionary(items.compactMap { i in (i["id"] as? String).map { ($0, i) } }, uniquingKeysWith: { a, _ in a })

        func tabs(under id: String) -> [(title: String, url: URL)] {
            guard let item = byID[id] else { return [] }
            if let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
               let s = tab["savedURL"] as? String, let url = URL(string: s) {
                // Only web pages: local files and arc:// pages don't carry over.
                guard url.scheme == "http" || url.scheme == "https" else { return [] }
                let title = item["title"] as? String ?? tab["savedTitle"] as? String ?? ""
                return [(title, url)]
            }
            return (item["childrenIds"] as? [String] ?? []).flatMap { tabs(under: $0) }
        }

        let spaces: [ImportedData.Space] = (main["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { s in
            let ids = s["containerIDs"] as? [Any] ?? []
            var pinned: [(String, URL)] = [], open: [(String, URL)] = []
            // Pairs of a marker ("pinned" / "unpinned") and that container's id.
            var i = 0
            while i + 1 < ids.count {
                if let kind = ids[i] as? String, let id = ids[i + 1] as? String {
                    if kind == "pinned" { pinned += tabs(under: id) } else if kind == "unpinned" { open += tabs(under: id) }
                }
                i += 2
            }
            let name = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space"
            guard !pinned.isEmpty || !open.isEmpty else { return nil }
            return ImportedData.Space(sourceID: s["id"] as? String ?? name, name: name, pinned: pinned, open: open)
        }

        let topIDs = main["topAppsContainerIDs"] as? [Any] ?? []
        let topApps = topIDs.compactMap { $0 as? String }.flatMap { tabs(under: $0) }
        return (spaces, topApps)
    }

    // MARK: Safari

    private static func safariBookmarks(_ file: URL) -> ([(title: String, url: URL)], [(title: String, url: URL)]) {
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return ([], []) }
        func link(_ node: [String: Any]) -> (String, URL)? {
            guard node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
                  let s = node["URLString"] as? String, let url = URL(string: s) else { return nil }
            return ((node["URIDictionary"] as? [String: Any])?["title"] as? String ?? "", url)
        }
        func walk(_ node: [String: Any], into list: inout [(title: String, url: URL)]) {
            if node["Title"] as? String == "com.apple.ReadingList" { return }
            if let l = link(node) { list.append(l) }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, into: &list) }
        }
        var all: [(title: String, url: URL)] = []
        walk(root, into: &all)
        let barNode = (root["Children"] as? [[String: Any]] ?? []).first { $0["Title"] as? String == "BookmarksBar" }
        let bar = (barNode?["Children"] as? [[String: Any]] ?? []).compactMap(link)
        return (all, bar)
    }

    private static func safariHistory(_ file: URL, since: Date?) throws -> [HistoryStore.ImportedVisit] {
        // Safari counts seconds since 2001.
        let sinceRef = since?.timeIntervalSinceReferenceDate ?? 0
        return try query(file, sql: """
            SELECT i.url, v.title, i.visit_count, MAX(v.visit_time) AS last FROM history_items i
            JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id HAVING last > \(sinceRef)
            ORDER BY i.visit_count DESC LIMIT 25000
            """) { row in
            guard let url = URL(string: row.text(0)) else { return nil }
            return .init(url: url, title: row.text(1), visitCount: Int(row.int(2)),
                         lastVisit: Date(timeIntervalSinceReferenceDate: row.double(3)), isBookmark: false)
        }
    }

    // MARK: SQLite

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }

    /// Runs a query on a copy of a browser's database: the browser may be running and holding a lock.
    private static func query<T>(_ file: URL, sql: String, map: (Row) -> T?) throws -> [T] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return [] }
        let tmp = fm.temporaryDirectory.appending(path: "browsa-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appending(path: file.lastPathComponent)
        do {
            try fm.copyItem(at: file, to: copy)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: file.path + suffix) {
                try? fm.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
            }
        } catch {
            throw file.path.hasPrefix(safariFolder.path) ? ImportError.needsFullDiskAccess : ImportError.unreadable(file.lastPathComponent)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ImportError.unreadable(file.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ImportError.unreadable(file.lastPathComponent) }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let v = map(Row(stmt: stmt)) { out.append(v) }
        }
        return out
    }
}

// MARK: - Landing it in Browsa

extension Library {
    /// Lands what was read: bookmarks and history into ⌘T's index, the top bookmarks as
    /// Favourites, Arc's spaces as spaces. Tabs come in unloaded, so nothing starts loading.
    @discardableResult
    func land(_ data: ImportedData, from source: ImportSource, options: ImportOptions) async -> ImportResult {
        var result = ImportResult()
        let now = Date.now
        if options.bookmarks != .skip {
            var seen = Set<String>()
            let marks = data.bookmarks.filter { seen.insert(URLNormalizer.key(for: $0.url)).inserted }
            _ = await history.importVisits(marks.map { .init(url: $0.url, title: $0.title, visitCount: 1, lastVisit: now, isBookmark: true) })
            result.bookmarks = marks.count
            if options.bookmarks == .searchAndFavourites {
                let room = max(0, options.favouriteCount - favorites.count)
                for b in data.bar.filter({ $0.url.scheme?.hasPrefix("http") == true }).prefix(room) where !isFavorite(b.url) {
                    addFavorite(url: b.url, title: b.title)
                    result.favourites += 1
                }
            }
        }
        if options.history {
            await history.importVisits(data.history)
            result.history = data.history.count
        }
        let importedKey = "importedSpaces"
        var already = Set(UserDefaults.standard.stringArray(forKey: importedKey) ?? [])
        for imported in data.spaces where options.includes(imported.sourceID) && !already.contains("\(source.id):\(imported.sourceID)") {
            already.insert("\(source.id):\(imported.sourceID)")
            let taken = Set(spaces.map(\.name))
            let name = taken.contains(imported.name) ? "\(imported.name) (\(source.name))" : imported.name
            let space = addSpace()
            space.name = name
            space.pinned = imported.pinned.map { BrowserTab(url: $0.url, title: $0.title, isPinned: true) }
            space.today = imported.open.map { BrowserTab(url: $0.url, title: $0.title) }
            result.spaces += 1
            result.tabs += imported.pinned.count + imported.open.count
        }
        UserDefaults.standard.set(Array(already), forKey: importedKey)
        scheduleSave()
        return result
    }
}
