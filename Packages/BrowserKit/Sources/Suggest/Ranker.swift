import Foundation

/// Merges and orders results from all local providers.
public enum Ranker {
    /// 0 visits -> 1.0; grows slowly so a site visited 200 times doesn't bury everything.
    public static func frecencyFactor(_ frecency: Double) -> Double {
        1.0 + log1p(max(0, frecency))
    }

    /// Seeds are capped below a site with ~2 typed visits (factor ≈ 2.6), so real history
    /// overtakes the bundled list quickly.
    public static func seedFactor(_ popularity: Double) -> Double {
        1.0 + min(max(popularity, 0), 1.3) * 1.2
    }

    static func kindBoost(_ kind: SuggestionKind) -> Double {
        switch kind {
        // Above any realistic history score (frecency 100 -> factor ≈ 5.6), so a matching
        // favourite is always the first row.
        case .favorite: 6.0
        case .openTab: 1.6
        case .bookmark: 1.3
        case .history: 1.0
        case .seed: 1.0
        case .searchQuery, .searchSuggestion: 1.0
        case .command: 1.1
        case .archived: 0.8
        case .remoteSite, .entity: 1.0
        }
    }

    /// Dedupe by URL (keeping the best-scoring kind) and sort.
    public static func rankLocal(_ all: [Suggestion], limit: Int) -> [Suggestion] {
        var best: [String: Suggestion] = [:]
        for var s in all {
            s.score *= kindBoost(s.kind)
            if let existing = best[s.dedupeKey], existing.score >= s.score { continue }
            best[s.dedupeKey] = s
        }
        return best.values
            .sorted { a, b in
                a.score != b.score ? a.score > b.score
                    : a.kind != b.kind ? a.kind < b.kind
                    : a.title < b.title
            }
            .prefix(limit).map { $0 }
    }
}
