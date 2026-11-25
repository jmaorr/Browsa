import SwiftUI
import AppKit
import Suggest

// A small card at the bottom of the sidebar for news we publish from browsa.app: a looping clip, a
// title, a line or two, and a button or two. The list is a plain JSON file
// (website/public/mac/announcements.json) fetched with no cookies, no query and nothing about you;
// the app sends nothing back. It's kept on disk, so offline the last copy is used, and any failure
// just means no card. Closing a card (or using its main button) hides that announcement for good.

/// One announcement, as published.
struct Announcement: Codable, Identifiable, Equatable {
    struct Action: Codable, Equatable {
        enum Kind: String, Codable { case enable, library, open }
        let title: String
        let action: Kind
        /// For `enable`: Library plugin ids to turn on (see `LibraryCatalog.plugins`).
        var plugins: [String]?
        /// For `library`: a page in the Library (a plugin or pack id); none for the front page.
        var target: String?
        /// For `open`: a web page.
        var url: URL?
    }

    let id: String
    let title: String
    let body: String
    /// A short muted loop, downloaded once before the card shows.
    var video: URL?
    /// Shown only from this app version on, and only until this date.
    var minVersion: String?
    var maxVersion: String?
    var expires: Date?
    var buttons: [Action]?
}

@MainActor @Observable
final class Announcements {
    static let shared = Announcements()
    static let published = URL(string: "https://browsa.app/mac/announcements.json")!
    /// For trying a card before it's published: `defaults write <bundle id> announcementsFeedURL file:///…/announcements.json`.
    /// A local feed may use local clips too.
    static var feed: URL {
        UserDefaults.standard.string(forKey: "announcementsFeedURL").flatMap(URL.init(string:)) ?? published
    }

    /// The announcement to show now, with its clip on disk if it has one.
    private(set) var current: Announcement?
    private(set) var clip: URL?

    private var all: [Announcement] = []
    private var dismissed: Set<String>
    private var started = false
    private static let dismissedKey = "announcements.dismissed"

    private init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// Loads the saved copy, then checks for a new one at launch and twice a day. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: Self.saved), let list = Self.decode(data) { all = list }
        Task { await pick() }
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed).sorted(), forKey: Self.dismissedKey)
        withAnimation(Motion.snappy) { current = nil; clip = nil }
        Task { await pick() }
    }

    // MARK: Fetching

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static var folder: URL {
        let dir = URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "com.orriginal.browsa")
            .appending(path: "Announcements")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var saved: URL { folder.appending(path: "announcements.json") }

    private static func decode(_ data: Data) -> [Announcement]? {
        struct File: Decodable { let announcements: [Announcement] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.announcements
    }

    private func refresh() async {
        let feed = Self.feed
        guard let (data, response) = try? await Self.session.data(from: feed),
              feed.isFileURL || (response as? HTTPURLResponse)?.statusCode == 200,
              let list = Self.decode(data) else { return }
        try? data.write(to: Self.saved, options: .atomic)
        all = list
        await pick()
    }

    /// The first announcement for this version that hasn't been closed, once its clip is ready.
    private func pick() async {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let next = all.first { a in
            !dismissed.contains(a.id)
                && (a.expires.map { $0 > .now } ?? true)
                && (a.minVersion.map { Self.compare(version, $0) >= 0 } ?? true)
                && (a.maxVersion.map { Self.compare(version, $0) <= 0 } ?? true)
        }
        guard let next else {
            if current != nil { withAnimation(Motion.snappy) { current = nil; clip = nil } }
            return
        }
        guard next != current else { return }
        var file: URL?
        if let video = next.video { file = await Self.download(video) }
        // Something else may have been picked or closed while the clip downloaded.
        guard !dismissed.contains(next.id), next != current else { return }
        withAnimation(Motion.spring) { clip = file; current = next }
    }

    /// The clip, saved by its file name so it's fetched once. Nil (card without a clip) if it can't be had.
    private static func download(_ url: URL) async -> URL? {
        if url.isFileURL, feed.isFileURL { return FileManager.default.fileExists(atPath: url.path) ? url : nil }
        guard url.scheme == "https" else { return nil }
        let file = folder.appending(path: "clip-" + url.lastPathComponent)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let (temp, response) = try? await session.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.moveItem(at: temp, to: file)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Compares dotted versions number by number: "1.3" < "1.3.1" < "1.10".
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// The card itself, above the sidebar's bottom row. Not shown in private windows.
struct AnnouncementCard: View {
    @Environment(Browser.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model = Announcements.shared

    var body: some View {
        ZStack {
            if let a = model.current, !browser.currentSpace.isPrivate {
                card(a)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: model.current?.id)
        .task { model.start() }
    }

    private func card(_ a: Announcement) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            if let clip = model.clip {
                Group {
                    if reduceMotion {
                        Color.secondary.opacity(0.1)
                    } else {
                        LoopingPlayer(url: clip)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(a.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.trailing, model.clip == nil ? 22 : 0)
                Text(a.body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let buttons = shownButtons(a)
                if !buttons.isEmpty {
                    HStack(spacing: 8) { buttonViews(buttons, a) }
                        .padding(.top, 6)
                }
            }
            .padding(10)
        }
        .background(.primary.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.06)))
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            Button { model.dismiss(a.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.mini)
            .padding(6)
            .help("Close")
        }
    }

    /// A button that turns things on is left out once they're all on.
    private func shownButtons(_ a: Announcement) -> [Announcement.Action] {
        (a.buttons ?? []).filter { b in
            guard b.action == .enable else { return true }
            let ids = (b.plugins ?? []).filter { LibraryCatalog.plugin($0) != nil }
            return !ids.isEmpty && !ids.allSatisfy { LibraryActions.isOn($0, in: browser) }
        }
    }

    /// The first button is the main one, a glass capsule at the trailing edge. The rest are flat text links at
    /// the leading edge, so the row never has to wrap in a narrow sidebar.
    @ViewBuilder
    private func buttonViews(_ buttons: [Announcement.Action], _ a: Announcement) -> some View {
        let others = Array(buttons.dropFirst())
        ForEach(Array(others.enumerated()), id: \.offset) { _, b in
            Button(b.title) { run(b, a) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(.rect)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        Spacer(minLength: 4)
        if let main = buttons.first {
            Button(main.title) { run(main, a) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .fixedSize()
        }
    }

    private func run(_ b: Announcement.Action, _ a: Announcement) {
        switch b.action {
        case .enable:
            let plugins = (b.plugins ?? []).compactMap(LibraryCatalog.plugin)
            for p in plugins { LibraryActions.set(p.id, on: true, in: browser, announce: false) }
            let names = plugins.map(\.title)
            let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
            if !list.isEmpty { browser.showToast("Turned on \(list)") }
            model.dismiss(a.id)
        case .library:
            browser.openLibrary(b.target)
        case .open:
            guard let url = b.url else { return }
            if LibraryPage.isLibrary(url) { browser.openLibrary(LibraryPage.target(url)) }
            else if url.scheme == "https" { browser.newTab(url: url, source: .link) }
        }
    }
}
