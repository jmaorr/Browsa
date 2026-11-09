import Foundation

/// What an agent's call touches, and so what the user has to have allowed first.
///
/// The Agent space is the agent's own: anything there runs without asking, on any site, so a
/// driving agent never stops for a prompt. What asks is the user's own stuff: one of their tabs,
/// or the list of them. Reading counts as much as clicking, since a signed-in page can leak either way.
public enum AgentAccess {
    /// One thing the user allows, until Browsa quits.
    public enum Grant: Hashable, Sendable {
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

    /// What has to be allowed for a call on `target`. Nothing in the Agent space; one of your
    /// tabs always, whatever site it's on, even your own dev server.
    public static func grants(target: Target?) -> [Grant] {
        guard let target, !target.inAgentSpace else { return [] }
        return [.yourTab(target.tabID, host: target.host)]
    }

    /// This Mac only. Not `.local`: that's your router or NAS, not your dev server.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}
