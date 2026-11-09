import Foundation

/// What an agent's call touches, and so what the user has to have allowed first.
///
/// Every call is judged by the tab and the site it touches, not by whether the tool only reads:
/// reading a signed-in tab can leak as much as clicking in it.
public enum AgentAccess {
    /// One thing the user allows.
    public enum Grant: Hashable, Sendable {
        /// Using pages on a site, in the Agent space.
        case site(String)
        /// Using one of the user's own tabs (outside the Agent space) while it's on this site.
        case yourTab(UUID, host: String)
        /// Seeing the titles and addresses of the user's own tabs.
        case yourTabs
    }

    /// The tab a call acts on.
    public struct Target: Sendable, Equatable {
        public let tabID: UUID
        public let host: String
        public let inAgentSpace: Bool
        public init(tabID: UUID, host: String, inAgentSpace: Bool) {
            self.tabID = tabID
            self.host = host
            self.inAgentSpace = inAgentSpace
        }
    }

    /// What has to be allowed for a call on `target` that may go to `destination`, a host.
    /// Your own dev servers never ask; one of your tabs always does, whatever site it's on.
    public static func grants(target: Target?, destination: String?) -> [Grant] {
        var out: [Grant] = []
        if let target {
            if !target.inAgentSpace {
                out.append(.yourTab(target.tabID, host: target.host))
            } else if needsAsking(target.host) {
                out.append(.site(target.host))
            }
        }
        if let destination, needsAsking(destination), !out.contains(.site(destination)) {
            out.append(.site(destination))
        }
        return out
    }

    static func needsAsking(_ host: String) -> Bool { !host.isEmpty && !isLoopback(host) }

    /// This Mac only. Not `.local`: that's your router or NAS, not your dev server.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The host a URL string points at, or "" when it has none (about:blank, a bad URL).
    public static func host(of url: String?) -> String {
        url.flatMap(URL.init(string:))?.host()?.lowercased() ?? ""
    }
}
