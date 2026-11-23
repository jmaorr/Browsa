import Foundation

/// The certificate a site showed, when the engine asks the app whether to trust it anyway.
/// Asked only for certificates the system wouldn't trust on its own: self-signed, expired,
/// the wrong name. A device on a home network (a router, Home Assistant) usually has one of these.
public struct ServerCertificate: Sendable, Equatable {
    public let host: String
    public let port: Int
    /// SHA-256 of the site's own certificate (the leaf), lowercase hex. An exception is for this
    /// certificate only: if the site starts showing a different one, Browsa asks again.
    public let fingerprint: String

    public init(host: String, port: Int, fingerprint: String) {
        self.host = Self.normalised(host)
        self.port = port
        self.fingerprint = fingerprint
    }

    /// "192.168.3.4:8123": what an exception is saved under.
    public var site: String { Self.site(host: host, port: port) }

    public static func site(host: String, port: Int?) -> String {
        "\(normalised(host)):\(port ?? 443)"
    }

    /// Hosts arrive with and without IPv6 brackets and in any case.
    static func normalised(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    /// Set on a certificate failure's NSError (userInfo) by the engine: the fingerprint of the
    /// certificate that was refused, so the error page can offer "Visit Anyway" for exactly that one.
    /// BrowserCore's `LoadError` reads the same key.
    public static let errorUserInfoKey = "BrowsaCertificateFingerprint"
}
