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

    var inline: InlineCompletion? { results?.inline }
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
        if let inline, inline.fullText == fieldText { return .open(inline.url) }
        let t = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let url = URLNormalizer.urlIfNavigable(t) { return .open(url) }
        return .search(t)
    }
}
