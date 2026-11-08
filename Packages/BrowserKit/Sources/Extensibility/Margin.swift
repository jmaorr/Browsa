import Foundation
import Observation

/// Margin: notes and comments pinned to web pages, which people and coding agents both read and act on.
///
/// You leave a note on a page (optionally on a quote or an element: "make this button bigger").
/// An agent connected over MCP lists the open ones, makes the change, replies and resolves them.
/// It's a to-do list that lives where the work is seen.
public struct MarginNote: Codable, Identifiable, Hashable, Sendable {
    public enum Author: Codable, Hashable, Sendable {
        case you
        /// A connected agent, by the name it gave when it connected ("Claude Code").
        case agent(String)

        public var name: String {
            switch self {
            case .you: "You"
            case .agent(let name): name
            }
        }
    }

    public enum Status: String, Codable, Hashable, Sendable { case open, resolved }

    public struct Reply: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var author: Author
        public var body: String
        public var createdAt = Date()

        public init(author: Author, body: String) {
            self.author = author
            self.body = body
        }
    }

    /// Where on the page the note points. All optional: a note can be about the whole page.
    public struct Anchor: Codable, Hashable, Sendable {
        /// The text it's about, as selected.
        public var quote: String?
        /// A CSS selector for the element, from the page's own picker.
        public var selector: String?
        /// Where it was on screen when made, in page coordinates, for drawing a pin if the selector fails.
        public var x: Double?
        public var y: Double?

        public init(quote: String? = nil, selector: String? = nil, x: Double? = nil, y: Double? = nil) {
            self.quote = quote
            self.selector = selector
            self.x = x
            self.y = y
        }

        public var isEmpty: Bool { quote == nil && selector == nil && x == nil }
    }

    public var id = UUID()
    /// `MarginStore.pageKey(_:)` of the page.
    public var page: String
    public var url: String
    public var pageTitle: String
    public var anchor: Anchor
    public var body: String
    public var author: Author
    public var status: Status = .open
    public var replies: [Reply] = []
    public var createdAt = Date()
    public var resolvedAt: Date?
    public var resolvedBy: Author?

    public init(url: URL, pageTitle: String, anchor: Anchor = .init(), body: String, author: Author = .you) {
        self.page = MarginStore.pageKey(url)
        self.url = url.absoluteString
        self.pageTitle = pageTitle
        self.anchor = anchor
        self.body = body
        self.author = author
    }
}

@MainActor @Observable
public final class MarginStore {
    public private(set) var notes: [MarginNote] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.iso.decode([MarginNote].self, from: data) {
            notes = saved
        }
    }

    /// Notes match a page by origin and path; the fragment and query are ignored, except on
    /// localhost, where the query often is the state being reviewed. "www." doesn't count.
    nonisolated public static func pageKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        let host = (c.host ?? "").lowercased()
        c.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if !(host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost")) { c.query = nil }
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        c.scheme = c.scheme?.lowercased()
        return c.string ?? url.absoluteString
    }

    // MARK: Reading

    public func notes(on url: URL) -> [MarginNote] {
        let key = Self.pageKey(url)
        return notes.filter { $0.page == key }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Every note on the same site, newest first: "you have 3 older notes from this site".
    public func notes(onSiteOf url: URL) -> [MarginNote] {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() else { return [] }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return notes.filter { URL(string: $0.url)?.host()?.lowercased().hasSuffix(site) == true }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// For agents: open notes, optionally only those on pages under `prefix` (e.g. "http://localhost:4322").
    public func openNotes(under prefix: String? = nil) -> [MarginNote] {
        notes.filter { note in
            guard note.status == .open else { return false }
            guard let prefix else { return true }
            return note.url.hasPrefix(prefix) || note.page.hasPrefix(prefix)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func note(_ id: UUID) -> MarginNote? { notes.first { $0.id == id } }

    // MARK: Changing

    @discardableResult
    public func add(_ note: MarginNote) -> MarginNote {
        notes.append(note)
        scheduleSave()
        return note
    }

    public func reply(to id: UUID, author: MarginNote.Author, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].replies.append(.init(author: author, body: body))
        scheduleSave()
    }

    public func resolve(_ id: UUID, by author: MarginNote.Author, comment: String? = nil) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let comment, !comment.isEmpty { notes[i].replies.append(.init(author: author, body: comment)) }
        notes[i].status = .resolved
        notes[i].resolvedAt = .now
        notes[i].resolvedBy = author
        scheduleSave()
    }

    public func reopen(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].status = .open
        notes[i].resolvedAt = nil
        notes[i].resolvedBy = nil
        scheduleSave()
    }

    public func edit(_ id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].body = body
        scheduleSave()
    }

    public func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Export

    /// The page's notes as Markdown, for pasting into an issue, a PR or a notes app.
    public func markdown(for url: URL) -> String {
        let list = notes(on: url)
        guard let first = list.first else { return "" }
        var out = "## Notes on [\(first.pageTitle.isEmpty ? first.url : first.pageTitle)](\(first.url))\n"
        for n in list {
            out += "\n- [\(n.status == .resolved ? "x" : " ")] \(n.body)"
            if let q = n.anchor.quote { out += "\n  > \(q)" }
            for r in n.replies { out += "\n  - \(r.author.name): \(r.body)" }
        }
        return out + "\n"
    }

    // MARK: Saving

    public func saveNow() {
        saveTask?.cancel()
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(notes).write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
