import Foundation

/// Where an installed extension comes from, and so how it updates.
public enum ExtensionSource: Codable, Hashable, Sendable {
    /// A Safari web extension inside an app on this Mac (1Password for Safari). It updates with its app.
    case safariApp(bundleID: String)
    /// A folder the user picked ("Load unpacked"). It never updates by itself; Browsa reloads it.
    case folder(path: String)
    /// The Chrome Web Store, by extension id (32 letters a–p).
    case chromeWebStore(id: String)
    /// addons.mozilla.org, by the add-on's slug or numeric id.
    case firefoxAddons(slug: String)

    /// Stable key for the catalog, e.g. "chrome:cjpalhdlnbpafiamejdnhcphjbkeiagm".
    public var key: String {
        switch self {
        case .safariApp(let id): "safari:\(id)"
        case .folder(let path): "folder:\(path)"
        case .chromeWebStore(let id): "chrome:\(id)"
        case .firefoxAddons(let slug): "firefox:\(slug)"
        }
    }

    /// Store installs: Browsa downloads, unpacks and updates these itself.
    public var isFromStore: Bool {
        switch self {
        case .chromeWebStore, .firefoxAddons: true
        case .safariApp, .folder: false
        }
    }

    /// Shown under the name in Settings and the Library.
    public var label: String {
        switch self {
        case .safariApp: "Safari, on this Mac"
        case .folder: "Unpacked folder"
        case .chromeWebStore: "Chrome Web Store"
        case .firefoxAddons: "Firefox Add-ons"
        }
    }

    /// Recognises a store page someone pasted: a Chrome Web Store or addons.mozilla.org link,
    /// or a bare Chrome extension id.
    public init?(link text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ChromeWebStore.isExtensionID(trimmed) {
            self = .chromeWebStore(id: trimmed)
        } else if let url = URL(string: trimmed), let id = ChromeWebStore.extensionID(from: url) {
            self = .chromeWebStore(id: id)
        } else if let url = URL(string: trimmed), let slug = FirefoxAddons.slug(from: url) {
            self = .firefoxAddons(slug: slug)
        } else {
            return nil
        }
    }
}

// MARK: - Chrome Web Store

/// The Chrome Web Store's public update service, the same one Chromium-based browsers use to
/// install and update store extensions. Browsa downloads on the user's behalf and never re-hosts.
public enum ChromeWebStore {
    /// The Chrome version Browsa says it is when asking for a package. Some extensions are only
    /// offered to recent versions.
    public static let productVersion = "140.0.0.0"

    public static func isExtensionID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// `https://chromewebstore.google.com/detail/<slug>/<id>` (and the older chrome.google.com/webstore form).
    public static func extensionID(from url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last { isExtensionID($0) }
    }

    /// Redirects to the extension's newest CRX package.
    public static func downloadURL(id: String) -> URL {
        url(response: "redirect", xs: ["id=\(id)&installsource=ondemand&uc"])
    }

    /// Asks which version is newest for several extensions at once. The reply is `UpdateManifest` XML.
    public static func updateCheckURL(ids: [String]) -> URL {
        url(response: "updatecheck", xs: ids.map { "id=\($0)&uc" })
    }

    /// Each `x` value is itself a query string, so its `&` and `=` must be escaped inside the outer one.
    private static func url(response: String, xs: [String]) -> URL {
        var inner = CharacterSet.urlQueryAllowed
        inner.remove(charactersIn: "&=+")
        let x = xs.map { "x=" + ($0.addingPercentEncoding(withAllowedCharacters: inner) ?? $0) }
        let query = (["response=\(response)", "acceptformat=crx2,crx3", "prodversion=\(productVersion)"] + x)
            .joined(separator: "&")
        return URL(string: "https://clients2.google.com/service/update2/crx?" + query)!
    }
}

/// One extension's answer in a Chrome update check.
public struct StoreRelease: Equatable, Sendable {
    public let id: String
    public let version: String
    public let downloadURL: URL
    /// SHA-256 of the package, hex, when the store says.
    public let sha256: String?

    public init(id: String, version: String, downloadURL: URL, sha256: String?) {
        self.id = id
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

/// Reads the `gupdate` XML a Chrome update check returns:
/// `<gupdate><app appid="…" status="ok"><updatecheck codebase="…" version="1.2" hash_sha256="…" status="ok"/></app></gupdate>`
public final class UpdateManifestParser: NSObject, XMLParserDelegate {
    private var currentApp: String?
    private var releases: [StoreRelease] = []

    public static func parse(_ data: Data) -> [StoreRelease] {
        let p = UpdateManifestParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.releases
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                       qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "app": currentApp = attributes["appid"]
        case "updatecheck":
            guard let id = currentApp, attributes["status"] ?? "ok" == "ok",
                  let version = attributes["version"], let codebase = attributes["codebase"],
                  let url = URL(string: codebase) else { return }
            releases.append(StoreRelease(id: id, version: version, downloadURL: url, sha256: attributes["hash_sha256"]))
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "app" { currentApp = nil }
    }
}

/// A Chrome extension package: a small signed header, then an ordinary zip.
public enum CRX {
    public enum Failure: Error, Equatable { case notACRX, unsupportedVersion(UInt32), truncated }

    /// The zip inside a CRX2 or CRX3 file. Signatures aren't checked: the package came straight
    /// from Google over HTTPS, and the hash in the update check is checked by the caller.
    public static func zipPayload(of data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // A plain zip (Firefox .xpi, or an already unwrapped package) passes straight through.
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data }
        guard bytes.count >= 12, bytes.starts(with: Array("Cr24".utf8)) else { throw Failure.notACRX }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        let version = u32(4)
        let start: Int
        switch version {
        case 3: start = 12 + Int(u32(8))
        case 2:
            guard bytes.count >= 16 else { throw Failure.truncated }
            start = 16 + Int(u32(8)) + Int(u32(12))
        default: throw Failure.unsupportedVersion(version)
        }
        guard start < bytes.count else { throw Failure.truncated }
        return Data(bytes[start...])
    }
}

// MARK: - Firefox Add-ons

/// addons.mozilla.org's public API. Add-ons there carry clear open-source licences more often than not.
public enum FirefoxAddons {
    /// `https://addons.mozilla.org/<locale>/firefox/addon/<slug>/`
    public static func slug(from url: URL) -> String? {
        guard url.host()?.lowercased() == "addons.mozilla.org" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(of: "addon"), parts.indices.contains(i + 1) else { return nil }
        return parts[i + 1]
    }

    public static func detailsURL(slug: String) -> URL {
        URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
    }

    /// The newest release from the details reply.
    public static func release(from data: Data) throws -> StoreRelease {
        let json = try JSONValue(data: data)
        guard let current = json["current_version"], let version = current["version"]?.string,
              let file = current["file"], let link = file["url"]?.string, let url = URL(string: link) else {
            throw URLError(.cannotParseResponse)
        }
        let slug = json["slug"]?.string ?? json["id"]?.int.map(String.init) ?? ""
        let hash = file["hash"]?.string.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return StoreRelease(id: slug, version: version, downloadURL: url, sha256: hash)
    }
}

// MARK: - Versions

/// Extension versions are 1–4 dot-separated integers ("1.2.10" > "1.2.9").
public func isVersion(_ a: String, newerThan b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}
