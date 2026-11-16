import SwiftUI
import Observation
import BrowserCore

/// Space Routing: some sites always open in a given Space (Arc called it Air Traffic Control; Zen
/// has Space Routing). With it on, a new Linear tab opens in Work and a new YouTube tab in Personal,
/// wherever you were.
///
/// Off until you turn it on (Settings › Spaces), or until you add a site from ⌘K. Then Browsa's
/// starter sets apply, matched to your Spaces by name, plus any sites you added yourself.
/// Only new tabs and links from other apps are routed. Following a link inside a tab never moves it,
/// private tabs never move, and sign-in and checkout pages stay next to the tab that opened them.
struct RouteRule: Codable, Identifiable, Equatable {
    var id = UUID()
    /// "github.com" (and its subdomains), optionally with a path: "github.com/acme".
    var pattern: String
    var spaceID: UUID

    var host: String { Self.host(of: pattern) }
    var pathPrefix: String? { Self.pathPrefix(of: pattern) }

    func matches(_ url: URL) -> Bool { Self.pattern(pattern, matches: url) }

    /// More specific rules (with a path, longer host) win.
    var specificity: Int { Self.specificity(of: pattern) }

    static func host(of pattern: String) -> String { String(pattern.split(separator: "/", maxSplits: 1).first ?? "") }

    static func pathPrefix(of pattern: String) -> String? {
        let parts = pattern.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? "/" + parts[1] : nil
    }

    static func specificity(of pattern: String) -> Int { pattern.count + (pathPrefix(of: pattern) == nil ? 0 : 1000) }

    static func pattern(_ pattern: String, matches url: URL) -> Bool {
        guard let h = url.host()?.lowercased() else { return false }
        let bare = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let host = host(of: pattern)
        guard bare == host || bare.hasSuffix("." + host) else { return false }
        guard let prefix = pathPrefix(of: pattern) else { return true }
        let path = url.path().lowercased()
        return path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// "github.com/acme/web" from a page's address, for a rule that covers just that path.
    static func pattern(for url: URL, depth: Int) -> String? {
        guard let h = url.host()?.lowercased() else { return nil }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let segments = url.pathComponents.dropFirst().prefix(depth).map { $0.lowercased() }
        return ([host] + segments).joined(separator: "/")
    }
}

/// A list of sites Browsa routes for you, to the Space whose name fits ("Work", "Personal").
struct StarterSet: Identifiable {
    let id: String
    let title: String
    /// Space names this set goes to, lowercased, best first.
    let spaceNames: [String]
    let patterns: [String]
    let onByDefault: Bool

    /// A few names, for the Settings row.
    var sample: String {
        let names = patterns.prefix(4).map { RouteRule.host(of: $0).split(separator: ".").first.map(String.init) ?? $0 }
        return names.joined(separator: ", ") + (patterns.count > 4 ? " +\(patterns.count - 4)" : "")
    }

    static let all: [StarterSet] = [
        StarterSet(id: "work", title: "Work tools", spaceNames: ["work", "office", "job", "business", "studio"], patterns: [
            "slack.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "linear.app", "atlassian.net", "notion.so", "figma.com",
            "miro.com", "loom.com", "asana.com", "github.com", "gitlab.com", "vercel.com", "dash.cloudflare.com",
            "app.hubspot.com", "force.com", "localhost", "127.0.0.1",
        ], onByDefault: true),
        StarterSet(id: "watching", title: "Watching and social", spaceNames: ["personal", "home", "life", "me", "fun"], patterns: [
            "youtube.com", "netflix.com", "open.spotify.com", "music.apple.com", "twitch.tv", "reddit.com", "instagram.com",
            "facebook.com", "tiktok.com", "x.com", "bsky.app", "letterboxd.com",
        ], onByDefault: true),
        StarterSet(id: "shopping", title: "Shopping and travel", spaceNames: ["personal", "home", "life", "me"], patterns: [
            "amazon.com", "amazon.com.au", "amazon.co.uk", "amazon.de", "amazon.ca", "ebay.com", "ebay.com.au", "ebay.co.uk",
            "etsy.com", "airbnb.com", "airbnb.com.au", "airbnb.co.uk", "booking.com", "skyscanner.net", "skyscanner.com.au",
        ], onByDefault: false),
    ]

    /// Sign-ins and checkouts open next to the tab that asked for them, or the flow breaks.
    static let neverRouted: [String] = [
        "accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "idmsa.apple.com",
        "okta.com", "auth0.com", "onelogin.com", "github.com/login", "github.com/sessions", "slack.com/signin",
        "checkout.stripe.com", "paypal.com", "pay.google.com",
    ]
}

@MainActor @Observable
final class SpaceRouter {
    static let shared = SpaceRouter()

    /// The Settings switch. Off by default: nothing moves until you ask.
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "spaceRoutingEnabled") } }

    /// Sites you added (⌘K or Settings). These beat the starter sets.
    private(set) var rules: [RouteRule] = [] { didSet { save(rules, "spaceRoutes") } }

    /// Which Space each starter set goes to, where you changed it. nil = off.
    private var setChoices: [String: String] = [:] { didSet { defaults.set(setChoices, forKey: "spaceRoutingSets") } }

    /// Sites taken out of a starter set, by set id ("Keep in …" on the toast, ⌘K "Stop Routing", Settings).
    private(set) var removed: [String: [String]] = [:] { didSet { defaults.set(removed, forKey: "spaceRoutingRemoved") } }

    /// Sites added to a starter set, by set id (Settings, or moved there from another set).
    private(set) var added: [String: [String]] = [:] { didSet { defaults.set(added, forKey: "spaceRoutingAdded") } }

    /// Sites whose first move has been explained with a toast.
    private var announced: Set<String> = [] { didSet { defaults.set(Array(announced), forKey: "spaceRoutingAnnounced") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "spaceRoutingEnabled")
        if let data = defaults.data(forKey: "spaceRoutes"), let saved = try? JSONDecoder().decode([RouteRule].self, from: data) {
            rules = saved
        }
        setChoices = defaults.dictionary(forKey: "spaceRoutingSets") as? [String: String] ?? [:]
        removed = defaults.dictionary(forKey: "spaceRoutingRemoved") as? [String: [String]] ?? [:]
        added = defaults.dictionary(forKey: "spaceRoutingAdded") as? [String: [String]] ?? [:]
        announced = Set(defaults.stringArray(forKey: "spaceRoutingAnnounced") ?? [])
    }

    private func save(_ rules: [RouteRule], _ key: String) {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: key) }
    }

    // MARK: Starter sets

    /// The Space a starter set goes to: the one you picked, else the first whose name fits, if it's on by default.
    func space(for set: StarterSet, in spaces: [Space]) -> Space? {
        if let choice = setChoices[set.id] {
            return choice == "off" ? nil : spaces.first { $0.id.uuidString == choice }
        }
        guard set.onByDefault else { return nil }
        return Self.namedSpace(for: set, in: spaces)
    }

    static func namedSpace(for set: StarterSet, in spaces: [Space]) -> Space? {
        for name in set.spaceNames {
            if let s = spaces.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }) { return s }
        }
        return nil
    }

    func choose(_ space: Space?, for set: StarterSet) { setChoices[set.id] = space?.id.uuidString ?? "off" }

    /// The set's sites as you've edited them: Browsa's list, minus what you removed, plus what you added.
    func sites(in set: StarterSet) -> [String] {
        let gone = Set(removed[set.id] ?? [])
        return (set.patterns + (added[set.id] ?? [])).filter { !gone.contains($0) }
    }

    /// Browsa's sites you took out of a set, for "Restore".
    func removedSites(in set: StarterSet) -> [String] { (removed[set.id] ?? []).filter { set.patterns.contains($0) } }

    var hasEdits: Bool { removed.values.contains { !$0.isEmpty } || added.values.contains { !$0.isEmpty } }

    func removeSite(_ pattern: String, from set: StarterSet) {
        if let i = added[set.id]?.firstIndex(of: pattern) { added[set.id]?.remove(at: i); return }
        if !(removed[set.id] ?? []).contains(pattern) { removed[set.id, default: []].append(pattern) }
    }

    func addSite(_ pattern: String, to set: StarterSet) {
        let p = Self.clean(pattern)
        guard !p.isEmpty else { return }
        if let i = removed[set.id]?.firstIndex(of: p) { removed[set.id]?.remove(at: i) }
        if !sites(in: set).contains(p) { added[set.id, default: []].append(p) }
    }

    /// One site to another set.
    func moveSite(_ pattern: String, from: StarterSet, to: StarterSet) {
        removeSite(pattern, from: from)
        addSite(pattern, to: to)
    }

    /// One site out of its set and into a rule of its own, for a Space.
    func moveSite(_ pattern: String, from: StarterSet, toRuleFor space: Space) {
        removeSite(pattern, from: from)
        add(pattern: pattern, to: space)
    }

    func restoreDefaults(of set: StarterSet) {
        removed[set.id] = nil
        added[set.id] = nil
    }

    static func clean(_ pattern: String) -> String {
        var p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        return p.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    // MARK: Routing

    struct Match {
        let space: Space
        /// The rule or starter-set site that matched, e.g. "linear.app".
        let pattern: String
        /// The starter set it came from; nil for your own rule.
        var setID: String?
    }

    /// Where a new tab for `url` belongs, if routing is on and a rule or starter set says so.
    func match(for url: URL?, in spaces: [Space]) -> Match? {
        guard isEnabled, let url, url.scheme == "http" || url.scheme == "https" else { return nil }
        if StarterSet.neverRouted.contains(where: { RouteRule.pattern($0, matches: url) }) { return nil }
        if let rule = rules.filter({ $0.matches(url) }).max(by: { $0.specificity < $1.specificity }),
           let space = spaces.first(where: { $0.id == rule.spaceID }) {
            return Match(space: space, pattern: rule.pattern)
        }
        var best: Match?
        for set in StarterSet.all {
            guard let space = space(for: set, in: spaces) else { continue }
            for p in sites(in: set) where RouteRule.pattern(p, matches: url) {
                if best == nil || RouteRule.specificity(of: p) > RouteRule.specificity(of: best!.pattern) {
                    best = Match(space: space, pattern: p, setID: set.id)
                }
            }
        }
        return best
    }

    func space(for url: URL?, in library: Library) -> Space? { match(for: url, in: library.regularSpaces)?.space }

    /// True the first time a site moves, so the toast explains it once.
    func shouldAnnounce(_ pattern: String) -> Bool {
        guard !announced.contains(pattern) else { return false }
        announced.insert(pattern)
        return true
    }

    // MARK: Changing rules

    /// Adding a site turns routing on: that's what you asked for.
    func add(pattern: String, to space: Space) {
        let p = Self.clean(pattern)
        guard !p.isEmpty else { return }
        rules.removeAll { $0.pattern == p }
        rules.append(RouteRule(pattern: p, spaceID: space.id))
        isEnabled = true
    }

    func remove(_ id: UUID) { rules.removeAll { $0.id == id } }

    /// Stop routing what `match` matched: your own rule goes, a starter site leaves its set.
    func stop(_ match: Match) {
        if let id = match.setID, let set = StarterSet.all.first(where: { $0.id == id }) {
            removeSite(match.pattern, from: set)
        } else {
            rules.removeAll { $0.pattern == match.pattern }
        }
    }

    /// Rules for Spaces that were deleted go too.
    func prune(keeping spaces: [Space]) {
        let ids = Set(spaces.map(\.id))
        if rules.contains(where: { !ids.contains($0.spaceID) }) { rules.removeAll { !ids.contains($0.spaceID) } }
    }

    // MARK: ⌘K

    /// ⌘K rows for the site in front: always there, so ⌘K is where people find routing.
    static func register(in workbench: Workbench, library: Library) {
        workbench.register(Tool(
            id: "routing", title: "Space Routing", symbol: "arrow.triangle.branch",
            summary: "Sites that always open in a given Space",
            liveCommands: { [weak library] in
                guard let library, let browser = library.activeWindow, let tab = browser.currentTab, !tab.isPrivate, let url = tab.url,
                      url.scheme == "http" || url.scheme == "https",
                      let host = RouteRule.pattern(for: url, depth: 0) else { return [] }
                let spaces = library.regularSpaces
                let current = shared.match(for: url, in: spaces)
                var out: [ToolCommand] = []
                if let current {
                    out.append(ToolCommand(id: "stop", title: "Stop Routing \(current.pattern) to \(current.space.name)",
                                           symbol: "arrow.triangle.branch", keywords: ["route", "space", "air traffic"]) { b in
                        shared.stop(current)
                        b.showToast("\(current.pattern) opens wherever you are")
                    })
                }
                for space in spaces where space.id != current?.space.id {
                    out.append(ToolCommand(id: "route-\(space.id.uuidString)", title: "Always Open \(host) in \(space.name)",
                                           symbol: space.symbol, keywords: ["route", "space", "routing", "air traffic"]) { b in
                        let wasOn = shared.isEnabled
                        shared.add(pattern: host, to: space)
                        b.showToast(wasOn ? "New \(host) tabs open in \(space.name)"
                                          : "Space Routing is on: new \(host) tabs open in \(space.name)")
                    })
                }
                if let deeper = RouteRule.pattern(for: url, depth: 1), deeper != host,
                   let space = spaces.first(where: { $0.id == browser.currentSpace.id }) {
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

// MARK: - Settings › Spaces

/// The switch, the starter sets and your own sites. Only the switch shows until it's on.
struct SpaceRoutingSettings: View {
    @Environment(Library.self) private var library
    @State private var newPattern = ""
    @State private var newSpaceID: UUID?
    /// The starter set whose sites are being edited.
    @State private var editing: String?

    private var router: SpaceRouter { .shared }

    private func sample(_ sites: [String]) -> String {
        let names = sites.prefix(4).map { RouteRule.host(of: $0).split(separator: ".").first.map(String.init) ?? $0 }
        return names.isEmpty ? "No sites" : names.joined(separator: ", ") + (sites.count > 4 ? " +\(sites.count - 4)" : "")
    }

    var body: some View {
        @Bindable var router = SpaceRouter.shared
        Section {
            Toggle(isOn: $router.isEnabled) {
                Text("Open sites in their Space")
                Text("New Linear tabs open in Work, YouTube in Personal, wherever you are.")
            }
        } footer: {
            if router.isEnabled {
                Text("Only new tabs and links from other apps move. Links you follow inside a tab stay put, and private tabs never move.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if router.isEnabled {
            Section("Starter sets") {
                ForEach(StarterSet.all) { set in
                    Picker(selection: Binding(
                        get: { router.space(for: set, in: library.regularSpaces)?.id },
                        set: { id in router.choose(library.regularSpaces.first { $0.id == id }, for: set) })) {
                        Text("Off").tag(UUID?.none)
                        ForEach(library.regularSpaces) { s in Text(s.name).tag(Optional(s.id)) }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(set.title)
                                Text(sample(router.sites(in: set))).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Edit Sites…") { editing = set.id }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
            .sheet(item: Binding(get: { editing.flatMap { id in StarterSet.all.first { $0.id == id } } },
                                 set: { editing = $0?.id })) { set in
                StarterSetEditor(set: set)
            }
            Section {
                ForEach(router.rules) { rule in
                    HStack {
                        Text(rule.pattern).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Text(library.regularSpaces.first { $0.id == rule.spaceID }?.name ?? "").foregroundStyle(.secondary)
                        Button { router.remove(rule.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop routing \(rule.pattern)")
                    }
                }
                addRow
            } header: {
                Text("Your sites")
            } footer: {
                Text("Or on any site, ⌘K › Always Open … in ….").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("github.com/acme", text: $newPattern, prompt: Text("github.com/acme"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(add)
            Picker("Space", selection: $newSpaceID) {
                ForEach(library.regularSpaces) { s in Text(s.name).tag(Optional(s.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 130)
            Button("Add", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            router.prune(keeping: library.regularSpaces)
            newSpaceID = newSpaceID ?? library.regularSpaces.first?.id
        }
    }

    private func add() {
        guard let id = newSpaceID, let space = library.regularSpaces.first(where: { $0.id == id }) else { return }
        router.add(pattern: newPattern, to: space)
        newPattern = ""
    }
}

/// One starter set's sites: take any out, send one to another set or to a rule of its own, add your own.
struct StarterSetEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let set: StarterSet
    @State private var newSite = ""

    private var router: SpaceRouter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.title).font(.headline)
                Text(router.space(for: set, in: library.regularSpaces).map { "Opens in \($0.name)" } ?? "Off")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            List {
                ForEach(router.sites(in: set), id: \.self) { site in
                    HStack {
                        Text(site).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Menu {
                            Section("Another set") {
                                ForEach(StarterSet.all.filter { $0.id != set.id }) { other in
                                    Button(other.title) { router.moveSite(site, from: set, to: other) }
                                }
                            }
                            Section("A rule of its own") {
                                ForEach(library.regularSpaces) { space in
                                    Button("Always Open in \(space.name)") { router.moveSite(site, from: set, toRuleFor: space) }
                                }
                            }
                        } label: { Text("Move") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button { router.removeSite(site, from: set) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Take \(site) out of \(set.title)")
                    }
                }
                let gone = router.removedSites(in: set)
                if !gone.isEmpty {
                    Section("Taken out") {
                        ForEach(gone, id: \.self) { site in
                            HStack {
                                Text(site).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button("Put Back") { router.addSite(site, to: set) }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            Divider()
            HStack(spacing: 8) {
                TextField("Add a site", text: $newSite, prompt: Text("figma.com/@acme"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer(minLength: 12)
                Button("Restore Defaults") { router.restoreDefaults(of: set) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
    }

    private func add() {
        router.addSite(newSite, to: set)
        newSite = ""
    }
}
