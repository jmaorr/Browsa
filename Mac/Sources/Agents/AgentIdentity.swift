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

/// An agent's app icon, or the fallback symbol.
struct AgentIcon: View {
    let caller: String
    var size: CGFloat = 14

    var body: some View {
        if let image = AgentIdentity.icon(for: caller) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: AgentIdentity.symbol).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}
