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

    var symbol: String {
        switch id {
        case "work": "briefcase"
        case "watching": "play.rectangle"
        default: "bag"
        }
    }

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

    /// Your own site, from its rule into a starter set.
    func moveRule(_ pattern: String, to set: StarterSet) {
        rules.removeAll { $0.pattern == pattern }
        addSite(pattern, to: set)
    }

    func hasEdits(in set: StarterSet) -> Bool { !(removed[set.id] ?? []).isEmpty || !(added[set.id] ?? []).isEmpty }

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

// MARK: - Settings › Space Routing

/// Its own Settings pane. One switch until it's on; then, Space by Space, what opens there: Browsa's
/// lists (each one a row that opens to its sites) and your own sites. Everything edits in place.
struct SpaceRoutingSettings: View {
    @Environment(Library.self) private var library
    @State private var adding = false

    private var router: SpaceRouter { .shared }
    private var spaces: [Space] { library.regularSpaces }

    var body: some View {
        @Bindable var router = SpaceRouter.shared
        Form {
            Section {
                Toggle(isOn: $router.isEnabled) {
                    Text("Open sites in their Space")
                    Text("New tabs for a site go to its Space, wherever you are. Links you follow inside a tab stay put, and private tabs never move.")
                }
            }
            if router.isEnabled {
                ForEach(spaces) { space in
                    let sets = StarterSet.all.filter { router.space(for: $0, in: spaces)?.id == space.id }
                    let rules = router.rules.filter { $0.spaceID == space.id }
                    Section {
                        ForEach(sets) { set in StarterSetRow(set: set) }
                        ForEach(rules) { rule in
                            SiteRow(pattern: rule.pattern) {
                                Section("Open in") {
                                    ForEach(spaces.filter { $0.id != space.id }) { other in
                                        Button(other.name, systemImage: other.symbol) { router.add(pattern: rule.pattern, to: other) }
                                    }
                                }
                                Section("Add to a list") {
                                    ForEach(StarterSet.all) { set in
                                        Button(set.title, systemImage: set.symbol) { router.moveRule(rule.pattern, to: set) }
                                    }
                                }
                            } onRemove: { router.remove(rule.id) }
                        }
                        if sets.isEmpty && rules.isEmpty {
                            Text("Nothing opens here yet.").foregroundStyle(.secondary)
                        }
                    } header: {
                        Label {
                            Text(space.name)
                        } icon: {
                            Image(systemName: space.symbol).foregroundStyle(SpacePalette.color(for: space))
                        }
                    }
                }
                let unused = StarterSet.all.filter { router.space(for: $0, in: spaces) == nil }
                if !unused.isEmpty {
                    Section("Not in use") {
                        ForEach(unused) { set in StarterSetRow(set: set) }
                    }
                }
                Section {
                    HStack {
                        Text("Your sites win over Browsa's lists. Sign-in and checkout pages always open next to the tab that asked for them.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Button("Add Site…") { adding = true }
                            .popover(isPresented: $adding, arrowEdge: .bottom) { AddSitePopover() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { router.prune(keeping: spaces) }
    }
}

/// One of Browsa's lists: its name, how many sites, which Space it opens in. Opens to its sites.
private struct StarterSetRow: View {
    @Environment(Library.self) private var library
    let set: StarterSet
    @State private var expanded = ProcessInfo.processInfo.environment["BROWSA_ROUTING_EXPAND"] == "1"

    private var router: SpaceRouter { .shared }
    private var spaces: [Space] { library.regularSpaces }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(router.sites(in: set), id: \.self) { site in
                SiteRow(pattern: site) {
                    Section("Move to a list") {
                        ForEach(StarterSet.all.filter { $0.id != set.id }) { other in
                            Button(other.title, systemImage: other.symbol) { router.moveSite(site, from: set, to: other) }
                        }
                    }
                    Section("Its own rule") {
                        ForEach(spaces) { space in
                            Button("Always Open in \(space.name)", systemImage: space.symbol) { router.moveSite(site, from: set, toRuleFor: space) }
                        }
                    }
                } onRemove: { router.removeSite(site, from: set) }
                // Under the list's own icon, not the disclosure arrow.
                .padding(.leading, 22)
            }
            let gone = router.removedSites(in: set)
            if !gone.isEmpty || router.hasEdits(in: set) {
                HStack {
                    Text(gone.isEmpty ? "Edited" : "\(gone.count) taken out")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Browsa's List") { router.restoreDefaults(of: set) }
                        .buttonStyle(.borderless)
                }
                .padding(.leading, 22)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: set.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(set.title)
                    Text("\(router.sites(in: set).count) sites").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Opens in", selection: Binding(
                    get: { router.space(for: set, in: spaces)?.id },
                    set: { id in router.choose(spaces.first { $0.id == id }, for: set) })) {
                    Text("Off").tag(UUID?.none)
                    Divider()
                    ForEach(spaces) { s in Label(s.name, systemImage: s.symbol).tag(Optional(s.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// A site: its icon and address, with Move and Remove on hover and in the context menu.
private struct SiteRow<MoveItems: View>: View {
    let pattern: String
    @ViewBuilder let moveItems: () -> MoveItems
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(url: URL(string: "https://" + RouteRule.host(of: pattern)) ?? URL(string: "https://example.com")!, size: 16,
                        letter: pattern)
            Text(pattern).lineLimit(1).truncationMode(.middle)
            Spacer()
            HStack(spacing: 4) {
                Menu {
                    moveItems()
                } label: {
                    Image(systemName: "arrow.turn.up.right")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Move \(pattern)")
                Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop routing \(pattern)")
            }
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Menu("Move") { moveItems() }
            Divider()
            Button("Stop Routing \(pattern)", role: .destructive, action: onRemove)
        }
    }
}

/// A site and the Space it opens in.
private struct AddSitePopover: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var spaceID: UUID?

    var body: some View {
        Form {
            TextField("Site", text: $pattern, prompt: Text("github.com/acme"))
            Picker("Opens in", selection: $spaceID) {
                ForEach(library.regularSpaces) { s in Label(s.name, systemImage: s.symbol).tag(Optional(s.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(SpaceRouter.clean(pattern).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { spaceID = spaceID ?? library.activeWindow?.currentSpace.id ?? library.regularSpaces.first?.id }
    }

    private func add() {
        guard let id = spaceID, let space = library.regularSpaces.first(where: { $0.id == id }) else { return }
        SpaceRouter.shared.add(pattern: pattern, to: space)
        dismiss()
    }
}
