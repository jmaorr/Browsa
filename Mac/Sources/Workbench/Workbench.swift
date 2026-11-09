import SwiftUI
import Observation

/// Every tool in Browsa, built in or from a plugin, plugs into the window the same way.
///
/// A tool can fill any of three places, and nothing else in the UI knows about tools one by one:
/// - **Panel**: the right-hand panel, beside the page (⌥⌘S switches it, the rail picks the tool).
/// - **Sidebar**: a small section under the tabs, for glanceable status.
/// - **Commands**: rows in the command bar (⌘K), which is also how you open a tool by name.
///
/// Built-in tools (Notes, Agents) register at launch. Plugins will register theirs from the
/// `browsa` block of their manifest, through the same `register`. Tools still being designed show
/// with sample data and a Preview badge, so the UI can be tuned before the feature is wired.
struct Tool: Identifiable {
    enum Owner: Hashable {
        case browsa
        /// A web extension or Browsa plugin, by its catalog id.
        case plugin(String)
    }

    enum Stage: Hashable {
        /// Works for real.
        case live
        /// The UI with sample data: for designing, not for use.
        case preview
    }

    let id: String
    var title: String
    /// SF Symbol.
    var symbol: String
    /// One line, for the command bar and the Library.
    var summary: String
    var owner: Owner = .browsa
    var stage: Stage = .live
    var panel: (@MainActor () -> AnyView)?
    var sidebar: (@MainActor () -> AnyView)?
    /// What the sidebar card shows while collapsed, beside the title: a glanceable status.
    var sidebarSummary: (@MainActor () -> AnyView)?
    /// True when there's nothing to show: the card hides until there is.
    var sidebarIsEmpty: (@MainActor () -> Bool)?
    var commands: [ToolCommand] = []
}

/// Something a tool can do from the command bar.
struct ToolCommand: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var symbol: String?
    var keywords: [String] = []
    let run: @MainActor (Browser) -> Void
}

@MainActor @Observable
final class Workbench {
    private(set) var tools: [Tool] = []
    /// Tools whose sidebar section is showing, in order. Saved.
    var sidebarToolIDs: [String] { didSet { UserDefaults.standard.set(sidebarToolIDs, forKey: "sidebarTools") } }

    init() {
        // Radar shows by default while it is being designed.
        sidebarToolIDs = UserDefaults.standard.stringArray(forKey: "sidebarTools") ?? ["radar"]
    }

    func register(_ tool: Tool) {
        if let i = tools.firstIndex(where: { $0.id == tool.id }) { tools[i] = tool } else { tools.append(tool) }
    }

    func unregister(owner: Tool.Owner) {
        tools.removeAll { $0.owner == owner }
    }

    func tool(_ id: String) -> Tool? { tools.first { $0.id == id } }

    var panelTools: [Tool] { tools.filter { $0.panel != nil } }
    var sidebarTools: [Tool] { sidebarToolIDs.compactMap { tool($0) }.filter { $0.sidebar != nil } }

    func toggleSidebar(_ id: String) {
        if let i = sidebarToolIDs.firstIndex(of: id) { sidebarToolIDs.remove(at: i) } else { sidebarToolIDs.append(id) }
    }

    /// For the command bar. Each panel tool gets an "Open …" row for free.
    var commands: [(tool: Tool, command: ToolCommand)] {
        tools.flatMap { tool -> [(tool: Tool, command: ToolCommand)] in
            var list = tool.commands.map { (tool: tool, command: $0) }
            if tool.panel != nil {
                list.insert((tool: tool, command: ToolCommand(id: "open", title: "Open \(tool.title)", subtitle: tool.summary,
                                                             symbol: tool.symbol, keywords: ["panel", "tool"]) { browser in
                    browser.showPanel(tool.id)
                }), at: 0)
            }
            if tool.sidebar != nil {
                let shown = sidebarToolIDs.contains(tool.id)
                list.append((tool: tool, command: ToolCommand(id: "sidebar", title: shown ? "Remove \(tool.title) from Sidebar" : "Add \(tool.title) to Sidebar",
                                                             symbol: "sidebar.left", keywords: ["sidebar", "section"]) { [weak self] _ in
                    self?.toggleSidebar(tool.id)
                }))
            }
            return list
        }
    }

    /// "tool:<tool>:<command>", the id the command bar hands back.
    static func commandID(_ tool: Tool, _ command: ToolCommand) -> String { "tool:\(tool.id):\(command.id)" }

    func run(commandID id: String, in browser: Browser) -> Bool {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "tool",
              let entry = commands.first(where: { $0.tool.id == parts[1] && $0.command.id == parts[2] }) else { return false }
        entry.command.run(browser)
        return true
    }
}
