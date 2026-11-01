import Foundation
import Observation
import Suggest

/// Drives the new-tab sheet: zero state (favourites, top sites, recent tabs) until the user
/// types, then streamed suggestions on every keystroke.
@MainActor @Observable
final class NewTabModel {
    /// What the user actually typed (never includes the inline completion tail).
    private(set) var typed = ""
    private(set) var zero: ZeroState?
    private(set) var results: SuggestResults?

    /// Keyboard highlight in `rows` (hardware arrows). nil = the field itself.
    private(set) var highlighted: Int?

    var inline: InlineCompletion? { results?.inline }

    /// Rows in on-screen order, so arrow keys walk them top to bottom.
    var rows: [Suggestion] {
        if isTyping {
            guard let r = results else { return [] }
            return r.local + (r.primary.map { [$0] } ?? []) + r.remote
        }
        guard let zero else { return [] }
        return zero.topSites + zero.recentTabs.map(Self.row(for:))
    }

    var highlightedSuggestion: Suggestion? {
        guard let highlighted, rows.indices.contains(highlighted) else { return nil }
        return rows[highlighted]
    }

    static func row(for t: OpenTabSnapshot) -> Suggestion {
        Suggestion(kind: .openTab, title: t.title, subtitle: URLNormalizer.displayHost(t.url),
                   action: .switchToTab(id: t.id, url: t.url), score: 0)
    }

    /// Down from the field goes to the first row; Up from the first row goes back to the field.
    func moveHighlight(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { highlighted = nil; return }
        switch highlighted {
        case nil: highlighted = delta > 0 ? 0 : nil
        case let i?:
            let j = i + delta
            highlighted = j < 0 ? nil : min(j, count - 1)
        }
    }

    func clearHighlight() { highlighted = nil }
    var isTyping: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty }

    private let engine: SuggestEngine
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: SuggestEngine) {
        self.engine = engine
    }

    func loadZeroState() async {
        zero = await engine.zeroState()
    }

    func textChanged(_ text: String, lastEditWasInsertion: Bool) {
        typed = text
        highlighted = nil
        task?.cancel()
        guard !text.isEmpty else { results = nil; return }
        let stream = engine.results(for: text, lastEditWasInsertion: lastEditWasInsertion)
        task = Task { [weak self] in
            for await r in stream {
                guard !Task.isCancelled, let self, self.typed == r.query else { return }
                self.results = r
            }
        }
    }

    /// What Return should do with the current field contents.
    func submitAction(fieldText: String) -> SuggestionAction? {
        if let s = highlightedSuggestion { return s.action }
        if let inline, inline.fullText == fieldText { return .open(inline.url) }
        let t = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let url = URLNormalizer.urlIfNavigable(t) { return .open(url) }
        return .search(t)
    }
}
