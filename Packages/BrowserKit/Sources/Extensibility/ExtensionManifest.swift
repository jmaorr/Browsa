import Foundation

/// The parts of a web extension's `manifest.json` Browsa reads before handing it to the engine:
/// what to call it, what it may touch, where its side panel lives, and its Browsa block.
public struct ExtensionManifest: Sendable, Equatable {
    public let raw: JSONValue
    public let name: String
    public let version: String
    public let manifestVersion: Int
    /// API permissions ("storage", "tabs"…).
    public let permissions: Set<String>
    /// Sites it can read and change ("<all_urls>", "https://*.example.com/*").
    public let hostPermissions: Set<String>
    /// A page for the right panel: Chrome's `side_panel.default_path` or Firefox's `sidebar_action.default_panel`.
    public let panelPath: String?
    /// Classic background script or module service worker, for the Chrome compatibility layer.
    public let background: Background?
    /// Browsa's own extension points (sidebar sections, commands, agent tools). Nil for an ordinary extension.
    public let browsa: BrowsaBlock?

    public enum Background: Sendable, Equatable {
        case serviceWorker(path: String, isModule: Bool)
        case scripts([String])
        case page(String)
    }

    public init(data: Data) throws {
        try self.init(json: JSONValue(data: data))
    }

    public init(json: JSONValue) throws {
        guard json.object != nil else { throw URLError(.cannotParseResponse) }
        raw = json
        // "__MSG_appName__" names are localised; the folder's _locales has the text. The caller can
        // replace it with `localizedName(in:)`.
        name = json["name"]?.string ?? "Untitled extension"
        version = json["version"]?.string ?? "0"
        manifestVersion = json["manifest_version"]?.int ?? 2
        let perms = (json["permissions"]?.array ?? []).compactMap(\.string)
        // MV2 mixes sites in with permissions; MV3 keeps them apart.
        let isSite = { (p: String) in p == "<all_urls>" || p.contains("://") }
        permissions = Set(perms.filter { !isSite($0) })
        let contentMatches = (json["content_scripts"]?.array ?? []).flatMap { ($0["matches"]?.array ?? []).compactMap(\.string) }
        hostPermissions = Set(perms.filter(isSite) + (json["host_permissions"]?.array ?? []).compactMap(\.string) + contentMatches)
        panelPath = json["side_panel"]?["default_path"]?.string ?? json["sidebar_action"]?["default_panel"]?.string
        if let bg = json["background"] {
            if let worker = bg["service_worker"]?.string {
                background = .serviceWorker(path: worker, isModule: bg["type"]?.string == "module")
            } else if let scripts = bg["scripts"]?.array?.compactMap(\.string), !scripts.isEmpty {
                background = .scripts(scripts)
            } else if let page = bg["page"]?.string {
                background = .page(page)
            } else {
                background = nil
            }
        } else {
            background = nil
        }
        browsa = try json["browsa"].map(BrowsaBlock.init(json:))
    }

    /// The extension's name with a `__MSG_x__` placeholder filled in from its `_locales` folder.
    public func localizedName(in folder: URL, locale: String = Locale.current.language.languageCode?.identifier ?? "en") -> String {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let defaultLocale = raw["default_locale"]?.string ?? "en"
        for loc in [locale, defaultLocale, "en"] {
            let file = folder.appending(path: "_locales/\(loc)/messages.json")
            guard let data = try? Data(contentsOf: file), let json = try? JSONValue(data: data),
                  let messages = json.object else { continue }
            if let hit = messages.first(where: { $0.key.lowercased() == key })?.value["message"]?.string { return hit }
        }
        return name
    }

    /// Everything it asks for, for comparing one version with the next. More than before means
    /// the update waits for the user, like Chrome.
    public var allPermissions: Set<String> {
        permissions.union(hostPermissions).union(browsa?.permissions ?? [])
    }
}

// MARK: - The browsa block

/// What a Browsa plugin adds on top of an ordinary web extension:
///
/// ```json
/// "browsa": {
///   "sidebar":  { "page": "radar.html", "title": "Dev servers" },
///   "panel":    { "page": "notes.html", "title": "Notes", "icon": "note" },
///   "commands": [ { "id": "open-staging", "title": "Open staging for this page" } ],
///   "agentTools": [ { "name": "flags_toggle", "description": "Turn a feature flag on or off",
///                     "inputSchema": { "type": "object", "properties": { "flag": { "type": "string" } } } } ]
/// }
/// ```
///
/// Each part is a permission the user sees before adding the plugin. The extension's background
/// script talks to Browsa with `browser.runtime.sendNativeMessage("app.browsa", …)`; see `PluginRequest`.
public struct BrowsaBlock: Sendable, Equatable {
    public struct Surface: Sendable, Equatable {
        public let page: String
        public let title: String?
        /// An SF Symbol name, for the panel rail.
        public let icon: String?
    }

    public struct Command: Sendable, Equatable {
        public let id: String
        public let title: String
        public let keywords: [String]
    }

    public struct AgentToolDeclaration: Sendable, Equatable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    public let sidebar: Surface?
    public let panel: Surface?
    public let commands: [Command]
    public let agentTools: [AgentToolDeclaration]
    /// It may put badges on tab rows.
    public let badges: Bool

    public init(json: JSONValue) throws {
        func surface(_ v: JSONValue?) -> Surface? {
            guard let v, let page = v["page"]?.string else { return nil }
            return Surface(page: page, title: v["title"]?.string, icon: v["icon"]?.string)
        }
        sidebar = surface(json["sidebar"])
        panel = surface(json["panel"])
        commands = (json["commands"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.string, let title = c["title"]?.string else { return nil }
            return Command(id: id, title: title, keywords: (c["keywords"]?.array ?? []).compactMap(\.string))
        }
        agentTools = (json["agentTools"]?.array ?? []).compactMap { t in
            guard let name = t["name"]?.string, AgentToolbox.isValidName(name) else { return nil }
            return AgentToolDeclaration(name: name, description: t["description"]?.string ?? "",
                                        inputSchema: t["inputSchema"] ?? ["type": "object"])
        }
        badges = json["badges"]?.bool ?? false
    }

    /// The Browsa permissions this block needs, shown on the add sheet.
    public var permissions: Set<String> {
        var p = Set<String>()
        if sidebar != nil { p.insert("browsa.sidebar") }
        if panel != nil { p.insert("browsa.panel") }
        if !commands.isEmpty { p.insert("browsa.commands") }
        if !agentTools.isEmpty { p.insert("browsa.agentTools") }
        if badges { p.insert("browsa.badges") }
        return p
    }
}

/// A message from a plugin's background script: `sendNativeMessage("app.browsa", { method, params })`.
public struct PluginRequest: Sendable, Equatable {
    /// The native messaging host name plugins send to.
    public static let hostName = "app.browsa"

    public enum Method: String, Sendable, CaseIterable {
        /// `{ tabId?, text, color? }`: a short badge on a tab row. Empty text clears it.
        case setBadge = "badge.set"
        /// `{ id, title }`: adds a command at run time (for results that change, like "Open PR #214").
        case registerCommand = "commands.register"
        /// `{ text }`: a short toast over the page.
        case toast = "ui.toast"
        /// `{ url, space? }`: opens a tab.
        case openTab = "tabs.open"
        /// `{ callID, result }`: answers an agent tool call Browsa forwarded with `agentTool.call`.
        case agentToolResult = "agentTool.result"
        /// `{ url? }`: the notes on a page, so a plugin can show or act on them.
        case listNotes = "notes.list"
    }

    public let method: Method
    public let params: JSONValue

    public init?(message: JSONValue) {
        guard let name = message["method"]?.string, let method = Method(rawValue: name) else { return nil }
        self.method = method
        params = message["params"] ?? [:]
    }
}

/// Permission names, in plain words, for the add sheet and Settings.
public func describePermission(_ permission: String) -> String? {
    switch permission {
    case "<all_urls>", "*://*/*", "http://*/*", "https://*/*": "Read and change every website you visit"
    case "tabs": "See the titles and addresses of your tabs"
    case "history": "Read and change your browsing history"
    case "bookmarks": "Read and change your bookmarks"
    case "nativeMessaging": "Talk to an app on your Mac"
    case "cookies": "Read and change cookies"
    case "downloads": "Manage your downloads"
    case "clipboardRead": "Read what you copy"
    case "browsa.sidebar": "Add a section to your sidebar"
    case "browsa.panel": "Add a panel on the right"
    case "browsa.commands": "Add commands to the command bar"
    case "browsa.agentTools": "Offer tools to coding agents you've connected"
    case "browsa.badges": "Put badges on your tabs"
    default: permission.contains("://") ? "Read and change \(permission)" : nil
    }
}

/// One line of the add sheet: what an extension may do, with the sites behind it when there are several.
public struct PermissionSummary: Hashable, Sendable {
    public let symbol: String
    public let text: String
    /// Site names behind a "pages on N sites" line, for a scrolling list.
    public let sites: [String]
}

extension ExtensionManifest {
    static let everySite: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]

    /// Sites first, folded into one line: every site, one site, or "N sites" with the list. A manifest that
    /// asks for every site and also names dozens (1Password does) shows just the one line.
    public var permissionSummary: [PermissionSummary] {
        var lines: [PermissionSummary] = []
        if !hostPermissions.isDisjoint(with: Self.everySite) {
            lines.append(.init(symbol: "globe", text: "Read and change every website you visit", sites: []))
        } else {
            let sites = Set(hostPermissions.compactMap(Self.siteName)).sorted()
            if sites.count == 1 {
                lines.append(.init(symbol: "globe", text: "Read and change pages on \(sites[0])", sites: []))
            } else if !sites.isEmpty {
                lines.append(.init(symbol: "globe", text: "Read and change pages on \(sites.count) sites", sites: sites))
            }
        }
        for permission in permissions.union(browsa?.permissions ?? []).sorted() where !permission.contains("://") {
            guard let text = describePermission(permission) else { continue }
            lines.append(.init(symbol: Self.symbol(for: permission), text: text, sites: []))
        }
        return lines
    }

    /// "https://*.example.com/*" → "example.com".
    static func siteName(_ pattern: String) -> String? {
        var host = pattern
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { $0 != "/" })
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        return host.isEmpty || host.contains("*") ? nil : host
    }

    static func symbol(for permission: String) -> String {
        switch permission {
        case "tabs": "square.on.square"
        case "history": "clock.arrow.circlepath"
        case "bookmarks": "bookmark"
        case "nativeMessaging": "app.connected.to.app.below.fill"
        case "cookies": "key.horizontal"
        case "downloads": "arrow.down.circle"
        case "clipboardRead": "doc.on.clipboard"
        case "browsa.sidebar": "sidebar.left"
        case "browsa.panel": "sidebar.right"
        case "browsa.commands": "command"
        case "browsa.agentTools": "sparkles"
        case "browsa.badges": "app.badge"
        default: "checkmark.shield"
        }
    }
}
