import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import BrowserCore

/// Space Routing: some sites always open in a given Space (Arc called it Air Traffic Control; Zen
/// has Space Routing). With it on, a new Linear tab opens in Work and a new YouTube tab in Personal,
/// wherever you were.
///
/// Off until you turn it on (Settings › Routing), or until you add a rule from ⌘K. Then your routing
/// sets apply (Browsa adds its Work and Personal ones the first time), plus your custom rules.
/// Only new tabs and links from other apps are routed. Following a link inside a tab never moves it,
/// private tabs and Favourites never move, and sign-in and checkout pages stay next to the tab that opened them.
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


/// A routing set: a list of sites and the Space they open in. Made from one of Browsa's sets, empty,
/// or imported from a file someone shared.
struct RouteSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sites: [String]
    /// nil until it's given a Space; a set without one routes nothing.
    var spaceID: UUID?
    /// The Browsa set it was made from, for "Restore Browsa's Version".
    var templateID: String?

    var template: StarterSet? { templateID.flatMap { id in StarterSet.all.first { $0.id == id } } }
    var differsFromTemplate: Bool { template.map { $0.patterns != sites } ?? false }

    /// What Export writes and Import reads.
    struct File: Codable {
        var browsaRoutingSet = 1
        var name: String
        var sites: [String]
    }
}

@MainActor @Observable
final class SpaceRouter {
    static let shared = SpaceRouter()

    /// The Settings switch. Off by default: nothing moves until you ask. The first time it goes on,
    /// Browsa's Work and Personal sets are added for Spaces with those names.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "spaceRoutingEnabled")
            if isEnabled { seedIfNeeded() }
        }
    }

    /// Your routing sets, in order.
    private(set) var sets: [RouteSet] = [] { didSet { save(sets, "spaceRoutingSetList") } }

    /// Custom rules: one address, one Space. These beat the sets.
    private(set) var rules: [RouteRule] = [] { didSet { save(rules, "spaceRoutes") } }

    /// Sites whose first move has been explained with a toast.
    private var announced: Set<String> = [] { didSet { defaults.set(Array(announced), forKey: "spaceRoutingAnnounced") } }

    private let defaults: UserDefaults
    /// The Spaces the seeding matches names against. Set by the Library at launch.
    @ObservationIgnored var spacesProvider: (() -> [Space])?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "spaceRoutingEnabled")
        sets = Self.load(defaults, "spaceRoutingSetList") ?? []
        rules = Self.load(defaults, "spaceRoutes") ?? []
        announced = Set(defaults.stringArray(forKey: "spaceRoutingAnnounced") ?? [])
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func seedIfNeeded() {
        guard !defaults.bool(forKey: "spaceRoutingSeeded") else { return }
        defaults.set(true, forKey: "spaceRoutingSeeded")
        let spaces = spacesProvider?() ?? []
        for template in StarterSet.all where template.onByDefault && !sets.contains(where: { $0.templateID == template.id }) {
            if let space = Self.namedSpace(for: template, in: spaces) { addSet(from: template, space: space) }
        }
    }

    static func namedSpace(for set: StarterSet, in spaces: [Space]) -> Space? {
        for name in set.spaceNames {
            if let s = spaces.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }) { return s }
        }
        return nil
    }

    // MARK: Sets

    @discardableResult
    func addSet(from template: StarterSet, space: Space?) -> RouteSet {
        let set = RouteSet(name: template.title, sites: template.patterns, spaceID: space?.id, templateID: template.id)
        sets.append(set)
        return set
    }

    @discardableResult
    func addEmptySet(name: String = "New Set", space: Space?) -> RouteSet {
        var name = name
        var n = 2
        while sets.contains(where: { $0.name == name }) { name = "New Set \(n)"; n += 1 }
        let set = RouteSet(name: name, sites: [], spaceID: space?.id)
        sets.append(set)
        return set
    }

    func hasSet(from template: StarterSet) -> Bool { sets.contains { $0.templateID == template.id } }

    func update(_ id: UUID, _ change: (inout RouteSet) -> Void) {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
        change(&sets[i])
    }

    func removeSet(_ id: UUID) { sets.removeAll { $0.id == id } }

    func duplicateSet(_ id: UUID) {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
        var copy = sets[i]
        copy.id = UUID()
        copy.name += " Copy"
        copy.templateID = nil
        sets.insert(copy, at: i + 1)
    }

    func restoreTemplate(_ id: UUID) {
        update(id) { set in if let t = set.template { set.sites = t.patterns } }
    }

    func addSite(_ pattern: String, to setID: UUID) {
        let p = Self.clean(pattern)
        guard !p.isEmpty else { return }
        update(setID) { if !$0.sites.contains(p) { $0.sites.append(p) } }
    }

    func removeSite(_ pattern: String, from setID: UUID) { update(setID) { $0.sites.removeAll { $0 == pattern } } }

    func renameSite(_ old: String, to new: String, in setID: UUID) {
        let p = Self.clean(new)
        guard !p.isEmpty, p != old else { return }
        update(setID) { set in
            set.sites.removeAll { $0 == p }
            if let i = set.sites.firstIndex(of: old) { set.sites[i] = p }
        }
    }

    func moveSite(_ pattern: String, from: UUID, to: UUID) {
        removeSite(pattern, from: from)
        addSite(pattern, to: to)
    }

    func moveSiteToNewSet(_ pattern: String, from: UUID) {
        let space = sets.first { $0.id == from }?.spaceID
        removeSite(pattern, from: from)
        let set = addEmptySet(name: RouteRule.host(of: pattern), space: nil)
        update(set.id) { $0.sites = [pattern]; $0.spaceID = space }
    }

    // MARK: Files

    func export(_ id: UUID) -> Data? {
        guard let set = sets.first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(RouteSet.File(name: set.name, sites: set.sites))
    }

    /// A set from a file Export wrote (or anyone wrote in that shape). It starts without a Space.
    func importSet(_ data: Data) -> Bool {
        guard let file = try? JSONDecoder().decode(RouteSet.File.self, from: data) else { return false }
        let sites = file.sites.map(Self.clean).filter { !$0.isEmpty }
        guard !sites.isEmpty else { return false }
        sets.append(RouteSet(name: file.name.isEmpty ? "Imported Set" : file.name, sites: sites, spaceID: nil))
        return true
    }

    // MARK: Custom rules

    /// Adding a rule turns routing on: that's what you asked for.
    func add(pattern: String, to space: Space) {
        let p = Self.clean(pattern)
        guard !p.isEmpty else { return }
        rules.removeAll { $0.pattern == p }
        rules.append(RouteRule(pattern: p, spaceID: space.id))
        isEnabled = true
    }

    func remove(_ id: UUID) { rules.removeAll { $0.id == id } }

    func setRuleSpace(_ id: UUID, to space: Space) {
        if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].spaceID = space.id }
    }

    func renameRule(_ id: UUID, to new: String) {
        let p = Self.clean(new)
        guard !p.isEmpty, let i = rules.firstIndex(where: { $0.id == id }), rules[i].pattern != p else { return }
        rules.removeAll { $0.pattern == p && $0.id != id }
        if let j = rules.firstIndex(where: { $0.id == id }) { rules[j].pattern = p }
    }

    static func clean(_ pattern: String) -> String {
        var p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        return p.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    // MARK: Routing

    struct Match {
        let space: Space
        /// The address that matched, e.g. "linear.app".
        let pattern: String
        /// The set it came from; nil for a custom rule.
        var setID: UUID?
    }

    /// Where a new tab for `url` belongs, if routing is on and a rule or set says so.
    func match(for url: URL?, in spaces: [Space]) -> Match? {
        guard isEnabled, let url, url.scheme == "http" || url.scheme == "https" else { return nil }
        if StarterSet.neverRouted.contains(where: { RouteRule.pattern($0, matches: url) }) { return nil }
        if let rule = rules.filter({ $0.matches(url) }).max(by: { $0.specificity < $1.specificity }),
           let space = spaces.first(where: { $0.id == rule.spaceID }) {
            return Match(space: space, pattern: rule.pattern)
        }
        var best: Match?
        for set in sets {
            guard let space = spaces.first(where: { $0.id == set.spaceID }) else { continue }
            for p in set.sites where RouteRule.pattern(p, matches: url) {
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

    /// Stop routing what `match` matched: a custom rule goes, a set's site leaves the set.
    func stop(_ match: Match) {
        if let id = match.setID { removeSite(match.pattern, from: id) } else { rules.removeAll { $0.pattern == match.pattern } }
    }

    /// Spaces that were deleted: their rules go, their sets wait for a new Space.
    func prune(keeping spaces: [Space]) {
        let ids = Set(spaces.map(\.id))
        if rules.contains(where: { !ids.contains($0.spaceID) }) { rules.removeAll { !ids.contains($0.spaceID) } }
        for set in sets where set.spaceID.map({ !ids.contains($0) }) ?? false { update(set.id) { $0.spaceID = nil } }
    }


    /// ⌘K rows for the site in front: always there, so ⌘K is where people find routing.
    static func register(in workbench: Workbench, library: Library) {
        shared.spacesProvider = { [weak library] in library?.regularSpaces ?? [] }
        // Turned on before sets existed (or before this build): add Browsa's sets once.
        if shared.isEnabled { shared.seedIfNeeded() }
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


// MARK: - Settings › Routing

/// Its own Settings pane. One switch until it's on; then your routing sets (each a row that opens to
/// its sites), an Add Set menu, and custom rules (one address, one Space). Everything edits in place.
struct SpaceRoutingSettings: View {
    @Environment(Library.self) private var library
    /// The Library's page has its own switch above this.
    var showsSwitch = true
    @State private var importFailed = false

    private var router: SpaceRouter { .shared }
    private var spaces: [Space] { library.regularSpaces }

    var body: some View {
        @Bindable var router = SpaceRouter.shared
        Form {
            if showsSwitch {
                Section {
                    Toggle(isOn: $router.isEnabled) {
                        Text("Open sites in their Space")
                        Text("New tabs for a site go to its Space, wherever you are. Links you follow inside a tab stay put, and private tabs and Favourites never move.")
                    }
                }
            }
            if router.isEnabled {
                Section {
                    ForEach(router.sets) { set in RouteSetRow(set: set) }
                    addSetMenu
                } header: {
                    Text("Routing sets")
                } footer: {
                    Text("A set is a list of sites and the Space they open in. Add Browsa's, make your own, or import one someone shared.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(router.rules) { rule in RuleRow(rule: rule) }
                    AddRuleRow()
                } header: {
                    Text("Custom rules")
                } footer: {
                    Text("Custom rules win over sets, and a more specific address wins over a shorter one. Sign-in and checkout pages always open next to the tab that asked for them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            router.spacesProvider = { [library] in library.regularSpaces }
            router.prune(keeping: spaces)
        }
        .alert("That file isn't a routing set", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Browsa can import a set it exported, or any JSON file with a name and a list of sites.")
        }
    }

    private var addSetMenu: some View {
        Menu {
            Section("From Browsa") {
                ForEach(StarterSet.all) { template in
                    let added = router.hasSet(from: template)
                    Button(added ? "\(template.title) (Added)" : "\(template.title) · \(template.patterns.count) sites") {
                        router.addSet(from: template, space: SpaceRouter.namedSpace(for: template, in: spaces))
                    }
                    .disabled(added)
                }
            }
            Divider()
            Button("Empty Set") { router.addEmptySet(space: library.activeWindow?.currentSpace ?? spaces.first) }
            Button("Import Set…", action: importSet)
        } label: {
            Label("Add Set…", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func importSet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if !router.importSet(data) { importFailed = true }
    }
}

/// The Space a set or rule opens in, as a pop-up.
private struct SpacePicker: View {
    let spaces: [Space]
    let selection: UUID?
    var allowsNone = false
    let onPick: (UUID?) -> Void

    var body: some View {
        Picker("Opens in", selection: Binding(get: { selection }, set: onPick)) {
            if allowsNone || selection == nil { Text("Choose…").tag(UUID?.none) }
            ForEach(spaces) { s in Label(s.name, systemImage: s.symbol).tag(Optional(s.id)) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// One routing set. The whole row opens and closes it; the Space and the ··· menu sit on the right.
private struct RouteSetRow: View {
    @Environment(Library.self) private var library
    let set: RouteSet
    @State private var expanded = false
    @State private var renaming = false
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var router: SpaceRouter { .shared }
    private var spaces: [Space] { library.regularSpaces }

    var body: some View {
        header
        if expanded {
            ForEach(set.sites, id: \.self) { site in
                SiteRow(pattern: site, removeTitle: "Remove from \(set.name)") {
                    Section("Move to Set") {
                        ForEach(router.sets.filter { $0.id != set.id }) { other in
                            Button(other.name) { router.moveSite(site, from: set.id, to: other.id) }
                        }
                        Button("New Set") { router.moveSiteToNewSet(site, from: set.id) }
                    }
                } onRename: { router.renameSite(site, to: $0, in: set.id) } onRemove: { router.removeSite(site, from: set.id) }
                .padding(.leading, 20)
            }
            AddSiteRow(placeholder: "Add a site to \(set.name)…") { router.addSite($0, to: set.id) }
                .padding(.leading, 20)
            if set.differsFromTemplate {
                HStack {
                    Text("Based on Browsa's \(set.template?.title ?? "set")").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Browsa's Version") { router.restoreTemplate(set.id) }.buttonStyle(.borderless)
                }
                .padding(.leading, 20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { _, on in if !on { commitName() } }
                } else {
                    Text(set.name)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer()
            Text("Opens in").foregroundStyle(.secondary)
            SpacePicker(spaces: spaces, selection: set.spaceID) { id in router.update(set.id) { $0.spaceID = id } }
            Menu {
                Button("Rename") { startRename() }
                Button("Duplicate") { router.duplicateSet(set.id) }
                Button("Export…", action: export)
                if set.differsFromTemplate {
                    Button("Restore Browsa's Version") { router.restoreTemplate(set.id) }
                }
                Divider()
                Button("Delete Set", role: .destructive) { router.removeSet(set.id) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options for \(set.name)")
        }
        // The whole row opens and closes the set, not just the arrow.
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
    }

    private var subtitle: String {
        let count = set.sites.count == 1 ? "1 site" : "\(set.sites.count) sites"
        if set.spaceID == nil { return count + " · choose a Space to use it" }
        return count + (set.templateID == nil ? " · your set" : "")
    }

    private func startRename() {
        nameDraft = set.name
        renaming = true
        nameFocused = true
    }

    private func commitName() {
        guard renaming else { return }
        renaming = false
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { router.update(set.id) { $0.name = name } }
    }

    private func export() {
        guard let data = router.export(set.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = set.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

/// A custom rule: its address (edited in place), its Space, and Remove.
private struct RuleRow: View {
    @Environment(Library.self) private var library
    let rule: RouteRule

    private var router: SpaceRouter { .shared }

    var body: some View {
        SiteRow(pattern: rule.pattern, removeTitle: "Remove Rule", trailing: {
            SpacePicker(spaces: library.regularSpaces, selection: rule.spaceID) { id in
                if let space = library.regularSpaces.first(where: { $0.id == id }) { router.setRuleSpace(rule.id, to: space) }
            }
            .labelsHidden()
        }) {
            EmptyView()
        } onRename: { router.renameRule(rule.id, to: $0) } onRemove: { router.remove(rule.id) }
    }
}

/// The last custom-rules row: an address and the Space it opens in; Return adds it.
private struct AddRuleRow: View {
    @Environment(Library.self) private var library
    @State private var draft = ""
    @State private var spaceID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").frame(width: 16).foregroundStyle(.secondary)
            TextField("Add a rule…", text: $draft, prompt: Text("Add an address, like github.com/acme"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit(add)
                .onExitCommand { draft = ""; focused = false }
            SpacePicker(spaces: library.regularSpaces, selection: spaceID) { spaceID = $0 }
            // Where the other rows' ··· sits, so the pickers line up.
            Color.clear.frame(width: 22, height: 18)
        }
        .onAppear { spaceID = spaceID ?? library.activeWindow?.currentSpace.id ?? library.regularSpaces.first?.id }
    }

    private func add() {
        guard let id = spaceID, let space = library.regularSpaces.first(where: { $0.id == id }),
              !SpaceRouter.clean(draft).isEmpty else { return }
        SpaceRouter.shared.add(pattern: draft, to: space)
        draft = ""
    }
}

/// A site: its icon and its address, edited right in the row, and a ··· menu with every option
/// in words (also on right-click).
private struct SiteRow<Trailing: View, MoveItems: View>: View {
    let pattern: String
    var removeTitle = "Remove"
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder let moveItems: () -> MoveItems
    let onRename: (String) -> Void
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(url: URL(string: "https://" + RouteRule.host(of: focused ? draft : pattern)) ?? URL(string: "https://example.com")!,
                        size: 16, letter: pattern)
            // Always a field: click the address and type, Return or clicking away saves, Esc puts it back.
            TextField("Site", text: $draft)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { draft = pattern; focused = false }
                .onChange(of: focused) { _, on in if !on { commit() } }
            if focused {
                Text("Return saves · Esc cancels").font(.caption).foregroundStyle(.secondary)
            }
            trailing()
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options for \(pattern)")
            .opacity(hovering && !focused ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .onAppear { draft = pattern }
        .onChange(of: pattern) { _, p in draft = p }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Edit Address") { focused = true }
        Divider()
        moveItems()
        Divider()
        Button(removeTitle, role: .destructive, action: onRemove)
    }

    private func commit() {
        let new = draft.trimmingCharacters(in: .whitespaces)
        if new.isEmpty || new == pattern { draft = pattern; return }
        onRename(new)
    }
}

extension SiteRow where Trailing == EmptyView {
    init(pattern: String, removeTitle: String = "Remove", @ViewBuilder moveItems: @escaping () -> MoveItems,
         onRename: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.init(pattern: pattern, removeTitle: removeTitle, trailing: { EmptyView() }, moveItems: moveItems,
                  onRename: onRename, onRemove: onRemove)
    }
}

/// The last row of a set: click, type an address, Return adds it.
private struct AddSiteRow: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").frame(width: 16).foregroundStyle(.secondary)
            TextField(placeholder, text: $draft, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit {
                    guard !SpaceRouter.clean(draft).isEmpty else { return }
                    onAdd(draft)
                    draft = ""
                }
                .onExitCommand { draft = ""; focused = false }
            if focused {
                Text("Return adds · Esc cancels").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
