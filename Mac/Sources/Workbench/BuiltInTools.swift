import SwiftUI
import AppKit
import BrowserEngine

/// Browsa's own tools, registered the way a plugin's will be.
@MainActor
enum BuiltInTools {
    static func register(in workbench: Workbench) {
        workbench.register(Tool(
            id: "notes", title: "Notes", symbol: "text.bubble",
            summary: "Notes on this page, for you and your agents",
            panel: { AnyView(MarginPanel()) },
            commands: [
                ToolCommand(id: "copy", title: "Copy Page Notes as Markdown", symbol: "doc.on.doc", keywords: ["export", "issue"]) { browser in
                    guard let url = browser.currentTab?.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(browser.library.margin.markdown(for: url), forType: .string)
                    browser.showToast("Copied notes as Markdown")
                },
            ]))

        workbench.register(Tool(
            id: "agents", title: "Agents", symbol: "sparkles",
            summary: "What connected agents are doing, and Stop",
            panel: { AnyView(AgentsPanel()) },
            commands: [
                ToolCommand(id: "stop", title: "Stop All Agents", symbol: "hand.raised", keywords: ["pause", "agent"]) { browser in
                    browser.library.agents.stopAll()
                    browser.showToast("Agents stopped")
                },
                ToolCommand(id: "space", title: "Go to Agent Space", symbol: "sparkles", keywords: ["agent", "space"]) { browser in
                    browser.selectSpace(browser.library.agents.agentSpace)
                },
            ]))

        // Designing in the real window before it's wired: sample servers, Preview badge.
        workbench.register(Tool(
            id: "radar", title: "Radar", symbol: "dot.radiowaves.left.and.right",
            summary: "Dev servers on this Mac, by project and branch",
            stage: .preview,
            panel: { AnyView(RadarPanel()) },
            sidebar: { AnyView(RadarSidebarSection()) },
            commands: RadarSample.servers.filter(\.isUp).map { s in
                ToolCommand(id: "open-\(s.port)", title: "Open \(s.project)", subtitle: "\(s.branch) · localhost:\(s.port)",
                            symbol: "dot.radiowaves.left.and.right", keywords: ["localhost", "dev", "server", s.branch]) { browser in
                    browser.newTab(url: URL(string: "http://localhost:\(s.port)"))
                }
            }))
    }

    /// An extension with a side panel becomes a panel tool, owned by that extension.
    static func sync(extensions: [EngineExtension], in workbench: Workbench) {
        for t in workbench.tools {
            if case .plugin(let id) = t.owner, !extensions.contains(where: { $0.id == id }) { workbench.unregister(owner: t.owner) }
        }
        for ext in extensions where ext.panelURL != nil {
            workbench.register(Tool(
                id: "ext:" + ext.id, title: ext.name, symbol: "puzzlepiece.extension",
                summary: "\(ext.name)'s side panel", owner: .plugin(ext.id),
                panel: { AnyView(ExtensionPanelView(extensionID: ext.id)) }))
        }
    }
}
