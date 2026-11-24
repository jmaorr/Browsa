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
            id: "agents", title: "Agents", symbol: AgentIdentity.symbol,
            summary: "What connected agents are doing, and Stop",
            panel: { AnyView(AgentsPanel()) },
            commands: [
                ToolCommand(id: "stop", title: "Stop All Agents", symbol: "hand.raised", keywords: ["pause", "agent"]) { browser in
                    browser.library.agents.stopAll()
                    browser.showToast("Agents stopped")
                },
                ToolCommand(id: "space", title: "Go to Agent Space", symbol: AgentIdentity.symbol, keywords: ["agent", "space"]) { browser in
                    browser.selectSpace(browser.library.agents.agentSpace)
                },
            ]))

        workbench.register(Tool(
            id: "boosts", title: "Boosts", symbol: "paintbrush.pointed",
            summary: "Your own font, colour and fewer distractions on this site",
            panel: { AnyView(BoostPanel()) },
            commands: [
                ToolCommand(id: "zap", title: "Zap Something on This Page", symbol: "scope", keywords: ["boost", "hide", "remove", "distraction"]) { browser in
                    ZapPicker.zapOnCurrentPage(in: browser)
                },
                ToolCommand(id: "toggle", title: "Turn Boost On or Off for This Site", symbol: "paintbrush.pointed", keywords: ["boost", "style"]) { browser in
                    guard browser.currentTab?.isPrivate != true else {
                        browser.showToast("Boosts aren't changed from private tabs"); return
                    }
                    guard var boost = BoostStore.shared.boost(for: browser.currentTab?.url) else {
                        browser.showToast("This site has no Boost yet")
                        return
                    }
                    boost.isOn.toggle()
                    BoostStore.shared.setOn(boost.id, boost.isOn)
                    if let page = browser.currentController?.page {
                        let updated = boost
                        Task { await BoostStore.shared.preview(updated, on: page) }
                    }
                    browser.showToast(boost.isOn ? "Boost on" : "Boost off")
                },
            ]))

        workbench.register(Tool(
            id: "downloads", title: "Downloads", symbol: "arrow.down.circle",
            summary: "Files you've downloaded, with Open and Show in Finder",
            panel: { AnyView(DownloadsPanel()) }))


        workbench.register(Tool(
            id: "performance", title: "Performance", symbol: "gauge.with.dots.needle.33percent",
            summary: "How hard Browsa is working, and which tabs are busy",
            panel: { AnyView(PerformancePanel()) }))

        workbench.register(Tool(
            id: "radar", title: "Radar", symbol: "dot.radiowaves.left.and.right",
            summary: "Dev servers on this Mac, by project and branch",
            panel: { AnyView(RadarPanel()) },
            sidebar: { AnyView(RadarSidebarSection()) },
            sidebarSummary: { AnyView(RadarSummary()) },
            // The card shows while something's running, and slides in when a server starts.
            sidebarIsEmpty: { !RadarStore.shared.hasRunning },
            liveCommands: {
                RadarStore.shared.servers.filter(\.isUp).map { s in
                    ToolCommand(id: "open-\(s.port)", title: "Open \(s.shortName)",
                                subtitle: [s.isWorktree ? s.project : s.branch, "localhost:\(s.port)"].filter { !$0.isEmpty }.joined(separator: " · "),
                                symbol: "dot.radiowaves.left.and.right", keywords: ["localhost", "dev", "server", s.project, s.branch, s.framework]) { browser in
                        RadarOpen.open(s, in: browser)
                    }
                }
            }))
    }

    /// An extension with a side panel becomes a panel tool, owned by that extension.
    static func sync(extensions: [EngineExtension], in workbench: Workbench) {
        for t in workbench.tools {
            if case .plugin(let id) = t.owner, !extensions.contains(where: { $0.id == id }) { workbench.unregister(owner: t.owner) }
        }
        for ext in extensions where ext.panelURL != nil { registerPanel(for: ext, in: workbench) }
    }

    static func registerPanel(for ext: EngineExtension, in workbench: Workbench) {
        workbench.register(Tool(
            id: "ext:" + ext.id, title: ext.name, symbol: "puzzlepiece.extension",
            summary: "\(ext.name)'s side panel", owner: .plugin(ext.id),
            panel: { AnyView(ExtensionPanelView(extensionID: ext.id)) }))
    }
}
