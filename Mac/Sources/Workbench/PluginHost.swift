import SwiftUI
import Observation
import BrowserEngine
import Extensibility

/// Browsa's side of plugins: a web extension with a `browsa` block in its manifest gets a panel, a
/// sidebar card and ⌘K commands, and talks to Browsa over native messaging (host "app.browsa").
///
/// From the plugin's background script:
/// ```js
/// const browsa = chrome.runtime.connectNative('app.browsa');
/// browsa.onMessage.addListener((m) => { if (m.event === 'command') … });   // ⌘K rows you declared
/// browsa.postMessage({ requestId: 1, method: 'ui.toast', params: { text: 'Hi' } });
/// // or one-off: await chrome.runtime.sendNativeMessage('app.browsa', { method: 'page.current' })
/// ```
/// See docs/plugins.md and examples/plugins/hello-browsa.
@MainActor @Observable
final class PluginHost {
    static let shared = PluginHost()

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let pluginID: String
        let text: String
        let isError: Bool
    }

    /// Plugins with an open port, which can receive events.
    private(set) var connected: Set<String> = []
    /// Commands plugins added while running (`commands.register`), by plugin.
    private(set) var runtimeCommands: [String: [BrowsaBlock.Command]] = [:]
    /// The last messages, newest first, for the Plugin Console.
    private(set) var log: [LogEntry] = []
    @ObservationIgnored private var senders: [String: @MainActor (Any) -> Void] = [:]
    @ObservationIgnored weak var library: Library?

    private init() {}

    // MARK: Messages

    func handle(_ message: Any, from pluginID: String) async -> PluginReply {
        guard let library else { return .unhandled }
        let json = JSONValue(any: message)
        guard let request = PluginRequest(message: json) else {
            record(pluginID, "unknown message \(json["method"]?.string ?? "(no method)")", error: true)
            return .failure("Unknown method. Browsa understands: \(PluginRequest.Method.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        record(pluginID, request.method.rawValue, error: false)
        let p = request.params
        let window = library.activeWindow
        switch request.method {
        case .toast:
            guard let text = p["text"]?.string, !text.isEmpty else { return .failure("ui.toast needs { text }") }
            window?.showToast(String(text.prefix(120)))
            return .value(true)
        case .openTab:
            guard let raw = p["url"]?.string, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else {
                return .failure("tabs.open needs an http(s) { url }")
            }
            let space = p["space"]?.string.flatMap { name in library.regularSpaces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            window?.newTab(url: url, in: space, source: .link)
            return .value(true)
        case .registerCommand:
            guard let id = p["id"]?.string, let title = p["title"]?.string else { return .failure("commands.register needs { id, title }") }
            var list = runtimeCommands[pluginID] ?? []
            list.removeAll { $0.id == id }
            if p["remove"]?.bool != true {
                list.append(BrowsaBlock.Command(id: id, title: title, keywords: (p["keywords"]?.array ?? []).compactMap(\.string)))
            }
            runtimeCommands[pluginID] = list
            return .value(true)
        case .currentPage:
            guard let tab = window?.currentTab, !tab.isPrivate else { return .value(NSNull()) }
            return .value(["url": tab.url?.absoluteString ?? "", "title": tab.displayTitle, "space": window?.currentSpace.name ?? ""] as [String: Any])
        case .listNotes:
            let url = p["url"]?.string.flatMap(URL.init(string:)) ?? window?.currentTab?.url
            guard let url else { return .value([Any]()) }
            let notes = library.margin.notes(on: url)
            let data = (try? JSONEncoder().encode(notes)) ?? Data("[]".utf8)
            return .value((try? JSONSerialization.jsonObject(with: data)) ?? [Any]())
        case .info:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            return .value(["app": "Browsa", "version": version, "api": 1,
                           "methods": PluginRequest.Method.allCases.map(\.rawValue)] as [String: Any])
        case .showPanel:
            let id = p["id"]?.string ?? "plugin:" + pluginID
            guard library.workbench.tool(id) != nil else { return .failure("No panel called \(id)") }
            window?.showPanel(id)
            return .value(true)
        case .setBadge, .agentToolResult:
            return .failure("\(request.method.rawValue) isn't wired up yet in this build")
        }
    }

    func portOpened(_ pluginID: String, send: @escaping @MainActor (Any) -> Void) {
        senders[pluginID] = send
        connected.insert(pluginID)
        record(pluginID, "connected", error: false)
    }

    func portClosed(_ pluginID: String) {
        senders[pluginID] = nil
        connected.remove(pluginID)
        record(pluginID, "disconnected", error: false)
    }

    /// Tells a plugin something happened: `{ event: "command", id }`.
    @discardableResult
    func send(event: String, _ fields: [String: Any] = [:], to pluginID: String) -> Bool {
        guard let send = senders[pluginID] else { return false }
        var body = fields
        body["event"] = event
        send(body)
        return true
    }

    private func record(_ pluginID: String, _ text: String, error: Bool) {
        log.insert(LogEntry(pluginID: pluginID, text: text, isError: error), at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
    }

    // MARK: Surfaces

    static func isPlugin(_ ext: EngineExtension) -> Bool {
        guard let data = ext.manifestJSON, let manifest = try? ExtensionManifest(data: data) else { return false }
        return manifest.browsa != nil
    }

    /// The Plugin Console, for people building plugins. Shown while Inspect Element is on.
    static func registerConsole(in workbench: Workbench) {
        workbench.register(Tool(
            id: "plugin-console", title: "Plugin Console", symbol: "terminal",
            summary: "Messages from Browsa plugins you're building",
            panel: { AnyView(PluginConsole()) },
            commands: [
                ToolCommand(id: "reload", title: "Reload Extensions and Plugins", symbol: "arrow.clockwise", keywords: ["plugin", "developer", "extension"]) { browser in
                    browser.library.reloadExtensions()
                    browser.showToast("Extensions reloaded")
                },
            ]))
    }

    /// Every loaded extension with a `browsa` block becomes a tool: its panel and sidebar pages, and
    /// its commands in ⌘K. Called whenever the extension list changes.
    func sync(extensions: [EngineExtension], in workbench: Workbench) {
        for ext in extensions {
            guard let data = ext.manifestJSON, let manifest = try? ExtensionManifest(data: data),
                  let block = manifest.browsa, let base = ext.baseURL else { continue }
            let pluginID = ext.id
            let page = { (path: String) in base.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path) }
            let panelURL = block.panel.map { page($0.page) }
            let sidebarURL = block.sidebar.map { page($0.page) }
            var tool = Tool(id: "plugin:" + pluginID, title: block.panel?.title ?? block.sidebar?.title ?? ext.name,
                            symbol: block.panel?.icon ?? "puzzlepiece.extension",
                            summary: "\(ext.name), a Browsa plugin", owner: .plugin(pluginID))
            if let panelURL { tool.panel = { AnyView(ExtensionPageView(url: panelURL)) } }
            if let sidebarURL {
                tool.sidebar = { AnyView(ExtensionPageView(url: sidebarURL).frame(height: 140)) }
            }
            tool.commands = block.commands.map { command(for: $0, pluginID: pluginID) }
            tool.liveCommands = { [weak self] in
                (self?.runtimeCommands[pluginID] ?? []).map { self?.command(for: $0, pluginID: pluginID) }.compactMap { $0 }
            }
            workbench.register(tool)
            // A plugin's sidebar card shows by default the first time it's added.
            let seenKey = "pluginSidebarShown." + pluginID
            if sidebarURL != nil, !UserDefaults.standard.bool(forKey: seenKey) {
                UserDefaults.standard.set(true, forKey: seenKey)
                if !workbench.sidebarToolIDs.contains(tool.id) { workbench.sidebarToolIDs.append(tool.id) }
            }
        }
    }

    private func command(for c: BrowsaBlock.Command, pluginID: String) -> ToolCommand {
        ToolCommand(id: c.id, title: c.title, symbol: "puzzlepiece.extension", keywords: c.keywords + ["plugin"]) { [weak self] browser in
            guard let self else { return }
            var fields: [String: Any] = ["id": c.id]
            if let tab = browser.currentTab, !tab.isPrivate, let url = tab.url {
                fields["tab"] = ["url": url.absoluteString, "title": tab.displayTitle]
            }
            if !self.send(event: "command", fields, to: pluginID) {
                browser.showToast("The plugin isn't listening. Its background has to connectNative(\"app.browsa\").")
            }
        }
    }
}

// MARK: - Library as the engine's plugin host

extension Library {
    func pluginMessage(_ message: Any, from extensionID: String) async -> PluginReply {
        PluginHost.shared.library = self
        return await PluginHost.shared.handle(message, from: extensionID)
    }

    func pluginPortOpened(extensionID: String, send: @escaping @MainActor (Any) -> Void) {
        PluginHost.shared.library = self
        PluginHost.shared.portOpened(extensionID, send: send)
    }

    func pluginPortClosed(extensionID: String) {
        PluginHost.shared.portClosed(extensionID)
    }
}

// MARK: - Pages

/// One page of an extension (a plugin's panel or sidebar card).
struct ExtensionPageView: View {
    @Environment(Browser.self) private var browser
    let url: URL
    @State private var page: (any EnginePage)?

    var body: some View {
        Group {
            if let page {
                PageHost(view: page.view, focusesPage: false)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            page?.close()
            page = browser.engine.makePage(options: PageOptions(url: url), delegate: PanelPageDelegate.shared)
            page?.load(url)
        }
        .onDisappear { page?.close(); page = nil }
    }
}

/// The Plugin Console: which plugins are connected and what they've asked for. For people building one.
struct PluginConsole: View {
    @Environment(Browser.self) private var browser
    private var host: PluginHost { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(host.connected.count) connected").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reload Extensions") { browser.library.reloadExtensions() }
                    .controlSize(.small)
                    .help("Load your plugin's files again after changing them")
            }
            Text("Plugins reach Browsa with connectNative(\"app.browsa\") or sendNativeMessage. Messages show here, newest first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if host.log.isEmpty {
                Text("Nothing yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(host.log) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(e.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(name(e.pluginID)).font(.caption.weight(.medium)).lineLimit(1)
                            Text(e.text).font(.caption.monospaced())
                                .foregroundStyle(e.isError ? Color.red : Color.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func name(_ id: String) -> String {
        browser.library.extensions.first { $0.id == id }?.name ?? id
    }
}
