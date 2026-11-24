#if os(macOS)
import Foundation
import WebKit

/// Small privacy switches, after Search's (Office Commun, MIT, Privacy.swift and CleanLink.swift).
enum PrivacySwitches {
    // MARK: Click IDs

    /// Query parameters that only say which ad or share a click came from.
    static let clickIDs: Set<String> = [
        "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "fbclid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "mc_eid", "igshid", "_hsenc", "_hsmi", "srsltid",
    ]

    /// `url` without click IDs, or nil when it has none.
    static func withoutClickIDs(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, items.contains(where: { clickIDs.contains($0.name.lowercased()) }) else { return nil }
        let kept = items.filter { !clickIDs.contains($0.name.lowercased()) }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    /// WebKit's own link-decoration filter, where this Mac has it (seen working on macOS 27.2).
    @MainActor static func filterLinkDecoration(_ on: Bool, in preferences: WKPreferences) {
        let list = NSSelectorFromString("_features"), set = NSSelectorFromString("_setEnabled:forFeature:")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: list), preferences.responds(to: set),
              let all = type.perform(list)?.takeUnretainedValue() as? [NSObject],
              let flag = all.first(where: { $0.value(forKey: "key") as? String == "FilterLinkDecorationByDefaultEnabled" }) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on, flag)
    }

    // MARK: Global Privacy Control

    /// The real `Sec-GPC` header and property, where WebKit offers them (macOS 27); the page script
    /// stands in for the property elsewhere.
    @MainActor static func globalPrivacyControl(_ on: Bool, in preferences: WKWebpagePreferences) {
        let setter = NSSelectorFromString("setGlobalPrivacyControlEnabled:")
        guard preferences.responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Setter.self)(preferences, setter, on)
    }

    static var nativeGlobalPrivacyControl: Bool {
        WKWebpagePreferences.instancesRespond(to: NSSelectorFromString("setGlobalPrivacyControlEnabled:"))
    }

    // MARK: Backspace

    /// ⌫ doesn't go back a page, as in Safari (a stray press outside a field lost what you were reading).
    @MainActor static func backspaceStays(_ preferences: WKPreferences) {
        let setter = NSSelectorFromString("_setBackspaceKeyNavigationEnabled:")
        guard preferences.responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Setter.self)(preferences, setter, false)
    }
}
#endif
