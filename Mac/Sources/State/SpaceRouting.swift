import SwiftUI
import Observation
import BrowserCore

/// Space Routing: some sites always open in a given Space (Arc called it Air Traffic Control; Zen
/// has Space Routing). "github.com/acme → Work" sends every new tab for that site, and links from
/// other apps, to Work, wherever you were.
///
/// Only new tabs are routed. Following a link inside a tab never moves it.
struct RouteRule: Codable, Identifiable, Equatable {
    var id = UUID()
    /// "github.com" (and its subdomains), optionally with a path: "github.com/acme".
    var pattern: String
    var spaceID: UUID

    var host: String { String(pattern.split(separator: "/", maxSplits: 1).first ?? "") }
    var pathPrefix: String? {
        let parts = pattern.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? "/" + parts[1] : nil
    }

    func matches(_ url: URL) -> Bool {
        guard let h = url.host()?.lowercased() else { return false }
        let bare = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        guard bare == host || bare.hasSuffix("." + host) else { return false }
        guard let prefix = pathPrefix else { return true }
        let path = url.path().lowercased()
        return path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// More specific rules (with a path, longer host) win.
    var specificity: Int { pattern.count + (pathPrefix == nil ? 0 : 1000) }

    /// "github.com/acme/web" from a page's address, for a rule that covers just that path.
    static func pattern(for url: URL, depth: Int) -> String? {
        guard let h = url.host()?.lowercased() else { return nil }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let segments = url.pathComponents.dropFirst().prefix(depth).map { $0.lowercased() }
        return ([host] + segments).joined(separator: "/")
    }
}

@MainActor @Observable
final class SpaceRouter {
    static let shared = SpaceRouter()

    private(set) var rules: [RouteRule] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "spaceRoutes") }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "spaceRoutes"),
           let saved = try? JSONDecoder().decode([RouteRule].self, from: data) {
            rules = saved
        }
    }

    func rule(for url: URL?) -> RouteRule? {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return rules.filter { $0.matches(url) }.max { $0.specificity < $1.specificity }
    }

    /// The Space a new tab for `url` belongs in, if a rule says so and that Space still exists.
    func space(for url: URL?, in library: Library) -> Space? {
        guard let rule = rule(for: url) else { return nil }
        return library.regularSpaces.first { $0.id == rule.spaceID }
    }

    func add(pattern: String, to space: Space) {
        let p = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !p.isEmpty else { return }
        rules.removeAll { $0.pattern == p }
        rules.append(RouteRule(pattern: p, spaceID: space.id))
    }

    func remove(_ id: UUID) { rules.removeAll { $0.id == id } }

    /// Rules for Spaces that were deleted go too.
    func prune(keeping spaces: [Space]) {
        let ids = Set(spaces.map(\.id))
        if rules.contains(where: { !ids.contains($0.spaceID) }) { rules.removeAll { !ids.contains($0.spaceID) } }
    }

    // MARK: Tool

    /// The Routing tool: a panel listing the rules, and ⌘K rows to route the site in front.
    static func register(in workbench: Workbench, library: Library) {
        workbench.register(Tool(
            id: "routing", title: "Routing", symbol: "arrow.triangle.branch",
            summary: "Sites that always open in a given Space",
            panel: { AnyView(RoutingPanel()) },
            liveCommands: { [weak library] in
                guard let library, let browser = library.activeWindow, let tab = browser.currentTab, !tab.isPrivate, let url = tab.url,
                      let host = RouteRule.pattern(for: url, depth: 0) else { return [] }
                var out: [ToolCommand] = []
                if let rule = shared.rule(for: url) {
                    let name = library.regularSpaces.first { $0.id == rule.spaceID }?.name ?? "a Space"
                    out.append(ToolCommand(id: "stop", title: "Stop Routing \(rule.pattern) to \(name)",
                                           symbol: "arrow.triangle.branch", keywords: ["route", "space", "air traffic"]) { b in
                        shared.remove(rule.id)
                        b.showToast("\(rule.pattern) opens anywhere again")
                    })
                }
                for space in library.regularSpaces where space.id != shared.rule(for: url)?.spaceID {
                    out.append(ToolCommand(id: "route-\(space.id.uuidString)", title: "Always Open \(host) in \(space.name)",
                                           symbol: space.symbol, keywords: ["route", "space", "routing", "air traffic"]) { b in
                        shared.add(pattern: host, to: space)
                        b.showToast("New \(host) tabs open in \(space.name)")
                    })
                }
                if let deeper = RouteRule.pattern(for: url, depth: 1), deeper != host, let space = library.regularSpaces.first(where: { $0.id == browser.currentSpace.id }) {
                    out.append(ToolCommand(id: "route-path", title: "Always Open \(deeper) in \(space.name)",
                                           symbol: space.symbol, keywords: ["route", "space", "routing", "path"]) { b in
                        shared.add(pattern: deeper, to: space)
                        b.showToast("New \(deeper) tabs open in \(space.name)")
                    })
                }
                return out
            }))
    }
}

/// The rules, by Space, and a field to add one.
struct RoutingPanel: View {
    @Environment(Browser.self) private var browser
    @State private var newPattern = ""
    @State private var newSpaceID: UUID?

    private var router: SpaceRouter { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("New tabs for these sites open in their Space, and so do links from other apps. Links you follow inside a tab stay put.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                addRow
                if router.rules.isEmpty {
                    Text("No routes yet. Try ⌘K › “Always Open … in …” on any site.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(browser.regularSpaces) { space in
                    let rules = router.rules.filter { $0.spaceID == space.id }
                    if !rules.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(space.name, systemImage: space.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SpacePalette.colors[space.colorIndex % SpacePalette.colors.count])
                            ForEach(rules) { rule in
                                HStack {
                                    Text(rule.pattern).font(.callout.monospaced()).lineLimit(1)
                                    Spacer()
                                    Button { router.remove(rule.id) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                        .help("Stop routing \(rule.pattern)")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            router.prune(keeping: browser.regularSpaces)
            if newPattern.isEmpty, let tab = browser.currentTab, !tab.isPrivate, let url = tab.url { newPattern = RouteRule.pattern(for: url, depth: 0) ?? "" }
            newSpaceID = newSpaceID ?? browser.currentSpace.id
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("github.com/acme", text: $newPattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Picker("Space", selection: $newSpaceID) {
                ForEach(browser.regularSpaces) { s in Text(s.name).tag(Optional(s.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 110)
            Button("Add", action: add).disabled(newPattern.isEmpty)
        }
        .controlSize(.small)
    }

    private func add() {
        guard let id = newSpaceID, let space = browser.regularSpaces.first(where: { $0.id == id }) else { return }
        router.add(pattern: newPattern, to: space)
        newPattern = ""
    }
}
