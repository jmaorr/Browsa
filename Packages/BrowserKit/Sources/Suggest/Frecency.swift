import Foundation

/// Frecency = frequency x recency. Each visit contributes a weight that halves every `halfLife`.
///
/// Stored incrementally so we never rescan visits: keep (score, lastUpdate) per URL and decay
/// the stored score forward to "now" before adding a new visit or reading it.
public struct Frecency: Sendable {
    public enum VisitSource: Sendable {
        case typed      // user typed or picked from autocomplete
        case link       // clicked a link on a page
        case bookmark   // opened from a favourite/bookmark
        case reload

        var weight: Double {
            switch self {
            case .typed: 2.0
            case .bookmark: 1.6
            case .link: 1.0
            case .reload: 0.1
            }
        }
    }

    public var halfLife: TimeInterval

    public init(halfLife: TimeInterval = 30 * 24 * 3600) {
        self.halfLife = halfLife
    }

    public func decayed(_ score: Double, from then: Date, to now: Date) -> Double {
        let dt = max(0, now.timeIntervalSince(then))
        return score * pow(0.5, dt / halfLife)
    }

    public func adding(_ source: VisitSource, to score: Double, lastUpdate: Date, now: Date) -> Double {
        decayed(score, from: lastUpdate, to: now) + source.weight
    }
}
