import Foundation
import CoreGraphics
import Observation
import Suggest

@MainActor @Observable
public final class BrowserTab: Identifiable {
    public let id: UUID
    public var url: URL?
    public var title: String
    public var isPinned: Bool
    public var lastActive: Date
    /// WKWebView.interactionState (back/forward list + scroll), saved when the web view is evicted.
    public var interactionState: Data?
    public var isPrivate: Bool

    // Live state mirrored from the web view (not persisted).
    public var estimatedProgress: Double = 0
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false
    /// Bottom bar collapsed to a small pill because the page is being scrolled down.
    public var isChromeCompact = false
    /// Set when the last load failed; the page area shows an error page with Retry.
    public var loadError: LoadError?
    /// Whether the current page was requested as the desktop site.
    public var isDesktopSite = false
    /// The colour WebKit shows beyond the page's edges. Nil until the page says.
    public var pageBackground: CGColor?
    /// A new web view hasn't drawn its page yet, so show the tab's last picture over it.
    public var isAwaitingFirstPaint = false

    public init(id: UUID = UUID(), url: URL?, title: String = "", isPinned: Bool = false,
                lastActive: Date = .now, interactionState: Data? = nil, isPrivate: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.lastActive = lastActive
        self.interactionState = interactionState
        self.isPrivate = isPrivate
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let url { return URLNormalizer.displayHost(url) }
        return "New Tab"
    }
}

@MainActor @Observable
public final class Space: Identifiable {
    public let id: UUID
    public var name: String
    /// SF Symbol name
    public var symbol: String
    /// Index into the app's space colour palette.
    public var colorIndex: Int
    public var pinned: [BrowserTab]
    public var today: [BrowserTab]
    public var selectedTabID: UUID?
    public var isSidebarOpen: Bool
    /// The Private space: shows in the spaces list only while it has tabs, and is never saved.
    public let isPrivate: Bool

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", colorIndex: Int = 0,
                pinned: [BrowserTab] = [], today: [BrowserTab] = [], selectedTabID: UUID? = nil, isSidebarOpen: Bool = true,
                isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.pinned = pinned
        self.today = today
        self.selectedTabID = selectedTabID
        self.isSidebarOpen = isSidebarOpen
        self.isPrivate = isPrivate
    }

    public var allTabs: [BrowserTab] { pinned + today }

    public var selectedTab: BrowserTab? {
        allTabs.first { $0.id == selectedTabID }
    }
}

// MARK: - Settings

public struct BrowserSettings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine = .google
    /// Send typed text to the search engine for suggestions. Off = local suggestions only.
    public var remoteSuggestions = true
    /// Today tabs untouched for this many hours move to the archive.
    public var archiveAfterHours: Double = 12
    /// Block ads and trackers with the built-in content rule list.
    public var blockContent = true
    /// Where links from other apps open.
    public var externalLinksSpaceID: UUID?
    /// Ask for desktop sites on the inner display (like iPad Safari) and mobile sites when folded.
    public var desktopSitesWhenUnfolded = true
    /// Per-site "Request Desktop/Mobile Site" choices, keyed by host. true = desktop.
    public var siteDesktopOverrides: [String: Bool] = [:]
    /// Remembered camera/microphone/motion answers, keyed by host then permission.
    public var sitePermissions: [String: [String: Bool]] = [:]
    /// Click "Reject" on cookie banners automatically (DuckDuckGo's autoconsent).
    public var declineCookieBanners = true
    /// Strip tracking parameters (utm_*, fbclid…) from links before they load.
    public var cleanLinks = true
    /// Which filter lists feed the ad/tracker blocker, when `blockContent` is on.
    public var filterGroups: Set<FilterGroup> = Set(FilterGroup.allCases)
    /// Sites where blocking (ads, trackers, cookie banners) is switched off. Hosts.
    public var blockingDisabledHosts: Set<String> = []

    public init() {}

    /// True when the user turned blockers off for this host (or a parent domain of it).
    public func blockingDisabled(for host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return blockingDisabledHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public init(from decoder: any Decoder) throws {
        // Decode field by field so settings saved by older builds still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchEngine = try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .google
        remoteSuggestions = try c.decodeIfPresent(Bool.self, forKey: .remoteSuggestions) ?? true
        archiveAfterHours = try c.decodeIfPresent(Double.self, forKey: .archiveAfterHours) ?? 12
        blockContent = try c.decodeIfPresent(Bool.self, forKey: .blockContent) ?? true
        externalLinksSpaceID = try c.decodeIfPresent(UUID.self, forKey: .externalLinksSpaceID)
        desktopSitesWhenUnfolded = try c.decodeIfPresent(Bool.self, forKey: .desktopSitesWhenUnfolded) ?? true
        siteDesktopOverrides = try c.decodeIfPresent([String: Bool].self, forKey: .siteDesktopOverrides) ?? [:]
        sitePermissions = try c.decodeIfPresent([String: [String: Bool]].self, forKey: .sitePermissions) ?? [:]
        declineCookieBanners = try c.decodeIfPresent(Bool.self, forKey: .declineCookieBanners) ?? true
        cleanLinks = try c.decodeIfPresent(Bool.self, forKey: .cleanLinks) ?? true
        filterGroups = try c.decodeIfPresent(Set<FilterGroup>.self, forKey: .filterGroups) ?? Set(FilterGroup.allCases)
        blockingDisabledHosts = try c.decodeIfPresent(Set<String>.self, forKey: .blockingDisabledHosts) ?? []
    }
}

/// One content blocker. WebKit caps each at 150,000 rules, so the filter lists are split
/// across several, the way AdGuard for iOS does it.
public enum FilterGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case ads, privacy, annoyances
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ads: "Ads"
        case .privacy: "Trackers"
        case .annoyances: "Annoyances"
        }
    }

    public var detail: String {
        switch self {
        case .ads: "AdGuard Base and Mobile Ads filters"
        case .privacy: "AdGuard Tracking Protection and Social Media filters"
        case .annoyances: "Cookie notices, pop-ups, app banners and widgets"
        }
    }

    /// AdGuard filter IDs (filters.adtidy.org), in iOS-optimised form.
    public var filterIDs: [Int] {
        switch self {
        case .ads: [2, 11]
        case .privacy: [3, 4]
        case .annoyances: [18, 19, 20, 21, 22]
        }
    }

    public var urls: [URL] {
        filterIDs.map { URL(string: "https://filters.adtidy.org/ios/filters/\($0)_optimized.txt")! }
    }

    /// One rule per line. AdGuard serves these lists with CRLF endings, and "\r\n" is a single
    /// Character in Swift, so splitting on "\n" alone would leave the whole list as one line.
    public static func rules(inFilterList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Why a page couldn't load, shown in place of the page.
public struct LoadError: Equatable, Sendable {
    public enum Kind: Sendable { case offline, notFound, timedOut, insecure, other }
    public let url: URL?
    public let kind: Kind
    public let detail: String

    public var title: String {
        switch kind {
        case .offline: "You're offline"
        case .notFound: "Can't find this site"
        case .timedOut: "The site took too long to respond"
        case .insecure: "This connection isn't private"
        case .other: "Couldn't open this page"
        }
    }

    public var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .notFound: "questionmark.app.dashed"
        case .timedOut: "clock.badge.exclamationmark"
        case .insecure: "lock.slash"
        case .other: "exclamationmark.triangle"
        }
    }

    /// Certificate problems get "Go Back", never a "Visit anyway".
    public var canRetry: Bool { kind != .insecure }

    public init(url: URL?, error: NSError) {
        self.url = url
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorDataNotAllowed), (NSURLErrorDomain, NSURLErrorInternationalRoamingOff):
            kind = .offline
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            kind = .notFound
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            kind = .timedOut
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted), (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid), (NSURLErrorDomain, NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain, NSURLErrorClientCertificateRequired):
            kind = .insecure
        default:
            kind = .other
        }
        detail = error.localizedDescription
    }

    /// Cancellations and "frame load interrupted" (a download took over) aren't failures.
    public static func isIgnorable(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code))
    }
}

// MARK: - Saved sites

/// A page put aside to read later, from the page menu's Save. A flat list, newest first, like the
/// saved posts in a social app. No folders.
public struct SavedSite: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var savedAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, savedAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.savedAt = savedAt
    }
}

// MARK: - Codable snapshot for persistence

struct TabRecord: Codable {
    var id: UUID, url: URL?, title: String, isPinned: Bool, lastActive: Date, interactionState: Data?
}

struct SpaceRecord: Codable {
    var id: UUID, name: String, symbol: String, colorIndex: Int
    var pinned: [TabRecord], today: [TabRecord], selectedTabID: UUID?, isSidebarOpen: Bool
}

struct BrowserSnapshot: Codable {
    var spaces: [SpaceRecord]
    var selectedSpaceID: UUID?
    var favorites: [Favorite]
    var archive: [TabRecord]
    var settings: BrowserSettings?
    /// Missing in state saved before Saved Sites existed.
    var saved: [SavedSite]?
}

extension BrowserTab {
    var record: TabRecord {
        TabRecord(id: id, url: url, title: title, isPinned: isPinned, lastActive: lastActive,
                  interactionState: interactionState)
    }
    convenience init(_ r: TabRecord) {
        self.init(id: r.id, url: r.url, title: r.title, isPinned: r.isPinned,
                  lastActive: r.lastActive, interactionState: r.interactionState)
    }
}

extension Space {
    var record: SpaceRecord {
        SpaceRecord(id: id, name: name, symbol: symbol, colorIndex: colorIndex,
                    pinned: pinned.map(\.record),
                    today: today.filter { !$0.isPrivate }.map(\.record),
                    selectedTabID: selectedTabID, isSidebarOpen: isSidebarOpen)
    }
    convenience init(_ r: SpaceRecord) {
        self.init(id: r.id, name: r.name, symbol: r.symbol, colorIndex: r.colorIndex,
                  pinned: r.pinned.map(BrowserTab.init), today: r.today.map(BrowserTab.init),
                  selectedTabID: r.selectedTabID, isSidebarOpen: r.isSidebarOpen)
    }
}
