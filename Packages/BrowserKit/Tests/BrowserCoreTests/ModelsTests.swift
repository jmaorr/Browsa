import Foundation
import Testing
@testable import BrowserCore

@Suite struct LoadErrorTests {
    func err(_ code: Int, _ domain: String = NSURLErrorDomain) -> NSError { NSError(domain: domain, code: code) }

    @Test func classifiesCommonFailures() {
        #expect(LoadError(url: nil, error: err(NSURLErrorNotConnectedToInternet)).kind == .offline)
        #expect(LoadError(url: nil, error: err(NSURLErrorCannotFindHost)).kind == .notFound)
        #expect(LoadError(url: nil, error: err(NSURLErrorTimedOut)).kind == .timedOut)
        let cert = LoadError(url: nil, error: err(NSURLErrorServerCertificateUntrusted))
        #expect(cert.kind == .insecure)
        #expect(!cert.canRetry)
    }

    @Test func cancellationsAndDownloadsAreNotErrors() {
        #expect(LoadError.isIgnorable(err(NSURLErrorCancelled)))
        #expect(LoadError.isIgnorable(err(102, "WebKitErrorDomain")))
        #expect(!LoadError.isIgnorable(err(NSURLErrorTimedOut)))
    }
}

@Suite struct SettingsCodingTests {
    @Test func olderSettingsStillLoad() throws {
        let old = #"{"searchEngine":{"duckDuckGo":{}},"remoteSuggestions":false,"archiveAfterHours":24,"blockContent":true}"#
        let s = try JSONDecoder().decode(BrowserSettings.self, from: Data(old.utf8))
        #expect(s.searchEngine == .duckDuckGo)
        #expect(s.remoteSuggestions == false)
        #expect(s.desktopSitesWhenUnfolded)
        #expect(s.sitePermissions.isEmpty)
    }

    @Test func roundTrips() throws {
        var s = BrowserSettings()
        s.siteDesktopOverrides["example.com"] = false
        s.sitePermissions["meet.google.com"] = ["camera": true]
        let back = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct ThumbnailStoreTests {
    @Test func keepsWantedPicturesAndDeletesTheRest() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir)
        let kept = UUID(), gone = UUID(), removed = UUID()
        store.save(Data([1]), for: kept)
        store.save(Data([2]), for: gone)
        store.save(Data([3]), for: removed)
        store.remove(removed)

        #expect(store.loadAll(keeping: [kept, removed]) == [kept: Data([1])])
        #expect(store.loadAll(keeping: [kept, gone]) == [kept: Data([1])])
    }
}

@Suite struct SnapshotCodingTests {
    @Test func stateFromBeforeSavedSitesStillLoads() throws {
        let old = #"{"spaces":[],"favorites":[],"archive":[]}"#
        let snap = try JSONDecoder().decode(BrowserSnapshot.self, from: Data(old.utf8))
        #expect(snap.saved == nil)
    }

    @Test func savedSitesRoundTrip() throws {
        let site = SavedSite(url: URL(string: "https://example.com/a")!, title: "A", savedAt: Date(timeIntervalSince1970: 1_000))
        let snap = BrowserSnapshot(spaces: [], selectedSpaceID: nil, favorites: [], archive: [], settings: nil, saved: [site])
        let back = try JSONDecoder().decode(BrowserSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(back.saved == [site])
    }
    @Test func tabsFromBeforeWindowKeysStillLoad() throws {
        let old = #"{"id":"6F1C2D4E-0000-4000-8000-000000000001","title":"A","isPinned":false,"lastActive":0}"#
        let record = try JSONDecoder().decode(TabRecord.self, from: Data(old.utf8))
        #expect(record.windowKey == nil)
    }

    @MainActor @Test func todayTabsKeepTheirWindowAndSharedTabsDont() throws {
        let window = UUID()
        let today = BrowserTab(url: URL(string: "https://example.com")!)
        today.windowKey = window
        let pinned = BrowserTab(url: URL(string: "https://example.org")!, isPinned: true)
        pinned.windowKey = window
        let decode = { (t: BrowserTab) in try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(t.record)) }
        #expect(BrowserTab(try decode(today)).windowKey == window)
        #expect(try decode(pinned).windowKey == nil)
    }
}
