#if os(macOS)
import Foundation
import CryptoKit
import BrowserCore

/// Which id and address a Chrome extension runs under.
///
/// Chrome serves an extension's pages from `chrome-extension://<its id>/` and tells the extension its
/// own id (`chrome.runtime.id`) as that same 32-letter id. Servers and apps go by both: Raindrop's
/// server only lets its own extension's origin in, and a native messaging host (1Password's app,
/// Bitwarden's) lists the extensions it talks to as `chrome-extension://<id>/`. So a Chrome Web Store
/// extension now gets exactly what Chrome gives it. The idea comes from Search (Office Commun, MIT),
/// which does the same in its Extensions.swift.
///
/// Before this, Browsa used WebKit's `webkit-extension://<uuid from the id>/` and the catalog key
/// ("chrome:<id>") as the extension's id. What an extension keeps is filed under those (chrome.storage
/// under its id, localStorage and IndexedDB under its address), so moving an extension that's already
/// installed would sign it out. Those keep the old pair ("legacy") until they're removed and added
/// again; extensions added from now on get Chrome's. `extensions.chromeAddressForAll` in Browsa's
/// defaults moves every one over, for testing.
@MainActor
enum ExtensionAddress {
    nonisolated static let chromeScheme = "chrome-extension"
    nonisolated static let webkitScheme = "webkit-extension"
    nonisolated static let schemes: Set<String> = [chromeScheme, webkitScheme]

    nonisolated static func isExtensionPage(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }

    struct Identity: Equatable, Sendable {
        /// What WebKit is told (WKWebExtensionContext.uniqueIdentifier): the extension's chrome.runtime.id.
        let uniqueIdentifier: String
        let baseURL: URL
        var usesChromeAddress: Bool { baseURL.scheme == ExtensionAddress.chromeScheme }
    }

    /// The Chrome Web Store id in a catalog key: "chrome:aeblfdkhhhdcdjpifhhbdiojplfjncoa" gives
    /// "aeblfdkhhhdcdjpifhhbdiojplfjncoa". Nil for anything else (folders, Firefox add-ons, Safari apps).
    nonisolated static func chromeID(fromCatalogID id: String) -> String? {
        guard id.hasPrefix("chrome:") else { return nil }
        let raw = String(id.dropFirst("chrome:".count))
        return isChromeID(raw) ? raw : nil
    }

    /// Chrome's ids are 32 letters from a to p (a SHA-256 prefix written that way).
    nonisolated static func isChromeID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The origin a native messaging host is told, and checks against its allowed_origins.
    nonisolated static func chromeOrigin(for catalogID: String) -> String? {
        chromeID(fromCatalogID: catalogID).map { "\(chromeScheme)://\($0)/" }
    }

    static func identity(for catalogID: String) -> Identity {
        if let raw = chromeID(fromCatalogID: catalogID), !isLegacy(catalogID),
           let url = URL(string: "\(chromeScheme)://\(raw)/") {
            return Identity(uniqueIdentifier: raw, baseURL: url)
        }
        return Identity(uniqueIdentifier: catalogID, baseURL: legacyBaseURL(for: catalogID))
    }

    /// webkit-extension://<uuid>/ derived from the id: Browsa's address before chrome-extension://, and
    /// still the one for Safari-app, Firefox and folder extensions.
    nonisolated static func legacyBaseURL(for id: String) -> URL {
        var bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = NSUUID(uuidBytes: bytes) as UUID
        return URL(string: "\(webkitScheme)://\(uuid.uuidString.lowercased())/")!
    }

    // MARK: Which ones stay where they were

    static let allKey = "extensions.chromeAddressForAll"

    private struct Record: Codable {
        /// Extensions that keep the old id and address.
        var legacy: Set<String> = []
        /// Extensions this build has decided about.
        var known: Set<String> = []
    }

    private static var file: URL { AppFolders.support.appending(path: "Extensions (WebKit)/addresses.json") }
    private static var record: Record?

    private static func load() -> Record {
        if let record { return record }
        let loaded = (try? JSONDecoder().decode(Record.self, from: Data(contentsOf: file))) ?? Record()
        record = loaded
        return loaded
    }

    private static func save(_ r: Record) {
        record = r
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(r).write(to: file, options: .atomic)
    }

    /// An extension an earlier build already ran (its prepared copy is there) keeps its address. One
    /// this build sees first, or added again after being removed, gets Chrome's.
    private static func isLegacy(_ catalogID: String) -> Bool {
        if UserDefaults.standard.bool(forKey: allKey) { return false }
        var r = load()
        if r.known.contains(catalogID) { return r.legacy.contains(catalogID) }
        let copy = AppFolders.support.appending(path: "Extensions (WebKit)")
            .appending(path: ExtensionCompat.folderName(for: catalogID))
        if FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) { r.legacy.insert(catalogID) }
        r.known.insert(catalogID)
        save(r)
        return r.legacy.contains(catalogID)
    }

    /// The extension was removed: added again, it starts afresh under Chrome's address.
    static func forget(_ catalogID: String) {
        var r = load()
        r.legacy.remove(catalogID)
        r.known.remove(catalogID)
        save(r)
        let copy = AppFolders.support.appending(path: "Extensions (WebKit)")
            .appending(path: ExtensionCompat.folderName(for: catalogID))
        try? FileManager.default.removeItem(at: copy)
    }
}
#endif
