import AppKit
import SwiftUI

/// Which agent is calling, as a picture. Agents say who they are when they connect ("claude-code",
/// "codex", "Cursor"). That name is the agent's own claim, fine for an icon, never for permissions.
///
/// Known agents show their app's icon when that app is installed on this Mac (Claude Code shows
/// the Claude app's icon), so Browsa ships no one else's logos. Anything else gets the fallback.
@MainActor
enum AgentIdentity {
    /// Agents and the Agent space, when there's no app to show.
    static let symbol = "pointer.arrow.ipad.rays"

    /// Name fragments, and the apps whose icon stands for them, best first.
    private static let apps: [(match: [String], bundleIDs: [String])] = [
        (["claude"], ["com.anthropic.claudefordesktop"]),
        (["codex", "openai", "chatgpt"], ["com.openai.codex", "com.openai.chat"]),
        (["cursor"], ["com.todesktop.230313mzl4w4u92"]),
        (["windsurf", "codeium"], ["com.exafunction.windsurf"]),
        (["zed"], ["dev.zed.Zed"]),
        (["copilot", "vscode", "visual studio code"], ["com.microsoft.VSCode"]),
    ]

    /// How to show an agent's name: "claude-code" reads as "Claude Code".
    nonisolated static func displayName(_ caller: String) -> String {
        let known = ["claude-code": "Claude Code", "claude code": "Claude Code", "codex": "Codex", "codex-mcp-client": "Codex",
                     "cursor": "Cursor", "cursor-vscode": "Cursor", "windsurf": "Windsurf", "zed": "Zed"]
        if let name = known[caller.lowercased()] { return name }
        guard caller.contains("-") || caller == caller.lowercased() else { return caller }
        return caller.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static var cache: [String: NSImage?] = [:]

    /// The installed app's icon for this agent, or nil.
    static func icon(for caller: String) -> NSImage? {
        let key = caller.lowercased()
        if let hit = cache[key] { return hit }
        let image = apps.first { $0.match.contains { key.contains($0) } }?.bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[key] = image
        return image
    }
}

/// An agent's app icon, or the Agent space's sparkle pointer.
struct AgentIcon: View {
    let caller: String
    var size: CGFloat = 14

    var body: some View {
        // Known agents: their app's icon. Browsa's own demo, and agents we don't recognise: the
        // Agent space's sparkle pointer.
        if let image = AgentIdentity.icon(for: caller) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: AgentIdentity.symbol).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}
