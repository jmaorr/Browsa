import Foundation

/// Scripts shipped in BrowserCore's bundle, for engines that live in other modules.
public enum BundledScripts {
    /// Mozilla's Readability (Apache-2.0), for Reader.
    public static let readability: String? = load("Readability")

    private static func load(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
