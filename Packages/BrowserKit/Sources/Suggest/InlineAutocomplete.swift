import Foundation

/// Safari/Chrome-style inline completion: typed "git" shows "git|hub.com" with the tail selected.
public struct InlineCompletion: Equatable, Sendable {
    /// Exactly what the user typed (case preserved).
    public let typed: String
    /// Text to append after `typed`, shown selected.
    public let completion: String
    /// Where Return goes if the user accepts.
    public let url: URL

    public var fullText: String { typed + completion }
}

public enum InlineAutocomplete {
    /// - Parameters:
    ///   - typed: current field text
    ///   - lastEdit: whether the last edit was an insertion. Never complete after a deletion,
    ///     otherwise Backspace fights the user.
    ///   - top: ranked local suggestions (best first)
    public static func completion(for typed: String, lastEditWasInsertion: Bool,
                                  top: [Suggestion]) -> InlineCompletion? {
        guard lastEditWasInsertion, !typed.isEmpty,
              !typed.contains(" "), !typed.contains("?") else { return nil }
        let needle = Matcher.stripForMatching(typed)
        guard !needle.isEmpty else { return nil }

        // Only the top row may complete (as in Safari): completing from a lower row would make the
        // field disagree with the first suggestion, e.g. "gh" showing GitHub but filling ghanaweb.com.
        guard let s = top.first, s.kind != .searchSuggestion, s.kind != .searchQuery, let url = s.url else { return nil }
        // Only complete host + first path segment, never a full URL with a query.
        let key = URLNormalizer.key(for: url)
        for target in completionTargets(for: key) where target.hasPrefix(needle.lowercased()) && target.count > needle.count {
            let tail = String(target.dropFirst(needle.count))
            let dest = URL(string: "https://" + target) ?? url
            // `typed` keeps the user's own casing and any scheme/www they typed.
            return InlineCompletion(typed: typed, completion: tail, url: dest)
        }
        return nil
    }

    /// "github.com/apple/swift?x=1" -> ["github.com", "github.com/apple"]
    static func completionTargets(for key: String) -> [String] {
        let noQuery = key.split(separator: "?", maxSplits: 1).first.map(String.init) ?? key
        let parts = noQuery.split(separator: "/", omittingEmptySubsequences: true)
        guard let host = parts.first else { return [] }
        var targets = [String(host)]
        if parts.count > 1 { targets.append(host + "/" + parts[1]) }
        return targets
    }
}
