import SwiftUI
import AppKit
import BrowserCore
import Extensibility
import BrowserEngine

/// The Library: everything you can add to Browsa, in one native page in a tab. Browsa's own
/// plugins (Notes, Agents, Radar, and the privacy features), the extensions you've added, verified
/// extensions to add in one click, and packs that switch on a set at once. Search first, toggles
/// everywhere, and the whole page works from the keyboard, like Raycast's Store.
enum LibraryPage {
    static let url = URL(string: "browsa://library")!
    static func isLibrary(_ url: URL?) -> Bool { url == LibraryPage.url }
}

extension Browser {
    /// Opens the Library tab, or goes to the one already open.
    func openLibrary() {
        let space = currentSpace.isPrivate ? regularSpaces[0] : currentSpace
        if let existing = space.allTabs.first(where: { LibraryPage.isLibrary($0.url) }) {
            select(existing)
        } else {
            // Like the welcome tab: no web page is made for it.
            let tab = library.insertTab(url: nil, in: space)
            tab.url = LibraryPage.url
            tab.title = "Library"
            select(tab)
        }
    }
}

// MARK: - Catalog

/// A Browsa plugin as the Library shows it. Built-in today; the same shape will describe plugins
/// from a manifest's `browsa` block, when that's opened up (see docs/library.md).
struct PluginInfo: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A workbench tool: panel, sidebar card, ⌘K rows.
        case tool
        /// One of Browsa's privacy features, a setting under the hood.
        case privacy
    }

    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let blurb: String
    /// Where it shows up: "Panel", "Sidebar", "⌘K", "Agent tools".
    let surfaces: [String]
    var kind = Kind.tool
    /// For the plugin's page: what it does, a sentence or two more than the blurb.
    var about = ""
}

/// A set of plugins switched on together.
struct PluginPack: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let plugins: [String]
    /// For the pack's page.
    var about = ""
}

/// An extension we've tested, from `verified-extensions.json`.
struct VerifiedExtension: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let category: String
    let tint: String
    let tested: String

    /// Its store icon, bundled as `ext-<id>.png`.
    var icon: NSImage? { Bundle.main.image(forResource: "ext-\(id)") }

    var storeURL: URL { URL(string: "https://chromewebstore.google.com/detail/\(id)")! }
    var color: Color {
        let hex = Int(tint.dropFirst(), radix: 16) ?? 0x888888
        return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

@MainActor
enum LibraryCatalog {
    static let plugins: [PluginInfo] = [
        .init(id: "notes", title: "Notes", symbol: "text.bubble.fill", tint: Color(red: 0.96, green: 0.71, blue: 0.04),
              blurb: "Notes on any page, for you and your agents.",
              surfaces: ["Panel", "⌘K", "Agent tools"],
              about: "Highlight text or pick anything on a page to leave a note. Notes stay with the page, show as pins while the panel is open, and connected agents can read, reply to and resolve them."),
        .init(id: "agents", title: "Agents", symbol: AgentIdentity.symbol, tint: .orange,
              blurb: "Let Claude Code, Codex or Cursor use Browsa.",
              surfaces: ["Panel", "⌘K", "MCP"],
              about: "Turns on Browsa's MCP server on this Mac. Agents open pages in their own Agent space, ask before touching your tabs, and stop when you press Stop."),
        .init(id: "radar", title: "Radar", symbol: "dot.radiowaves.left.and.right", tint: .green,
              blurb: "Your local dev servers, one click away.",
              surfaces: ["Sidebar", "Panel", "⌘K"],
              about: "Finds the dev servers running on this Mac, names them by project and branch, and reloads a tab by itself when its server comes back."),
        .init(id: "privacy-blocking", title: "Ad & Tracker Blocker", symbol: "hand.raised.fill", tint: .blue,
              blurb: "Blocks ads and trackers on every site.",
              surfaces: ["Every page"], kind: .privacy,
              about: "Uses well-known filter lists, updated in the background. Turn it off for a single site from the site menu in the address bar."),
        .init(id: "privacy-cookies", title: "Cookie Banner Decliner", symbol: "checkmark.shield.fill", tint: .indigo,
              blurb: "Says no to cookie banners for you.",
              surfaces: ["Every page"], kind: .privacy,
              about: "Uses DuckDuckGo's open-source Autoconsent to pick the most private choice on cookie banners and dismiss them."),
        .init(id: "privacy-links", title: "Clean Links", symbol: "link", tint: .teal,
              blurb: "Removes tracking from links you open.",
              surfaces: ["Every link"], kind: .privacy,
              about: "Removes known tracking parameters before a page loads, so sites can't follow you from link to link."),
    ]

    static var toolPlugins: [PluginInfo] { plugins.filter { $0.kind == .tool } }
    static var privacyPlugins: [PluginInfo] { plugins.filter { $0.kind == .privacy } }
    static func plugin(_ id: String) -> PluginInfo? { plugins.first { $0.id == id } }
    static func pack(_ id: String) -> PluginPack? { packs.first { $0.id == id } }

    static let agentPack = PluginPack(
        id: "agent-pack", title: "Agent Pack",
        blurb: "Build with an AI agent beside you.",
        plugins: ["radar", "notes", "agents"],
        about: "Radar finds your dev servers, Notes holds your feedback on pages, and Agents lets Claude Code, Codex or Cursor work through Browsa while you watch.")

    static let privacyPack = PluginPack(
        id: "privacy-pack", title: "Privacy Pack",
        blurb: "Fewer ads, trackers and cookie banners.",
        plugins: ["privacy-blocking", "privacy-cookies", "privacy-links"],
        about: "On from the start. Ads and trackers are blocked, cookie banners are declined for you, and tracking is stripped from links before pages load.")

    static let packs = [agentPack, privacyPack]

    /// Bundled today; the same file can come from browsa.app later, so the list grows without an update.
    static let verified: [VerifiedExtension] = {
        struct File: Decodable { let extensions: [VerifiedExtension] }
        guard let url = Bundle.main.url(forResource: "verified-extensions", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.extensions
    }()
}

// MARK: - Turning things on and off

@MainActor
enum LibraryActions {
    static func isOn(_ id: String, in browser: Browser) -> Bool {
        let library = browser.library
        switch id {
        case "privacy-blocking": return library.settings.blockContent
        case "privacy-cookies": return library.settings.declineCookieBanners
        case "privacy-links": return library.settings.cleanLinks
        default: return library.workbench.isEnabled(id)
        }
    }

    static func set(_ id: String, on: Bool, in browser: Browser, announce: Bool = true) {
        let library = browser.library
        switch id {
        case "privacy-blocking": library.settings.blockContent = on
        case "privacy-cookies": library.settings.declineCookieBanners = on
        case "privacy-links": library.settings.cleanLinks = on
        default:
            library.workbench.setEnabled(id, on)
            if id == "agents" { library.agents.isEnabled = on }   // Agents is the MCP endpoint itself.
            if id == "radar", on, !library.workbench.sidebarToolIDs.contains("radar") { library.workbench.toggleSidebar("radar") }
            if !on, browser.panel == id { browser.panel = nil }
        }
        guard announce, let p = LibraryCatalog.plugin(id) else { return }
        browser.showToast(on ? "\(p.title) is on" : "\(p.title) is off")
    }

    /// The Agent Pack, for onboarding and the Library's pack card.
    static func setAgentPack(_ on: Bool, in browser: Browser) { setPack(LibraryCatalog.agentPack, on: on, in: browser) }

    static func setPack(_ pack: PluginPack, on: Bool, in browser: Browser) {
        for id in pack.plugins { set(id, on: on, in: browser, announce: false) }
    }

    static func togglePack(_ pack: PluginPack, on: Bool, in browser: Browser) {
        setPack(pack, on: on, in: browser)
        browser.showToast(on ? "Turned on the \(pack.title)" : "Turned off the \(pack.title)")
    }

    static func isPackOn(_ pack: PluginPack, in browser: Browser) -> Bool {
        pack.plugins.allSatisfy { isOn($0, in: browser) }
    }
}

// MARK: - Page

/// One thing the keyboard can land on, in page order.
enum LibraryItem: Hashable {
    case pack(String)
    case plugin(String)
    case verified(String)
    case installed(String)
}

struct LibraryView: View {
    @Environment(Browser.self) private var browser
    @State private var search = ""
    /// The page open over the list: a plugin's or a pack's id.
    @State private var detail: String?
    /// The pack a plugin's page was opened from, so Back returns there.
    @State private var parentPack: String?
    @State private var focused: LibraryItem?
    @State private var addingChrome = false
    @State private var preview: Library.ExtensionPreview?
    @State private var problem: String?
    @FocusState private var searchFocused: Bool
    @State private var keys = LibraryKeys()

    private var library: Library { browser.library }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    private var packs: [PluginPack] { LibraryCatalog.packs.filter { matches($0.title, $0.blurb, "pack") } }
    private var tools: [PluginInfo] { LibraryCatalog.toolPlugins.filter { matches($0.title, $0.blurb) } }
    private var privacy: [PluginInfo] { LibraryCatalog.privacyPlugins.filter { matches($0.title, $0.blurb, "privacy") } }
    private var installed: [InstalledExtension] { library.extensionCatalog.items.filter { matches($0.name, $0.source.label) } }
    private var verified: [VerifiedExtension] { LibraryCatalog.verified.filter { matches($0.name, $0.blurb, $0.category) } }
    /// Safari extensions running from apps on this Mac; they aren't in the catalog.
    private var safari: [EngineExtension] {
        let catalogued = Set(library.extensionCatalog.items.map(\.id))
        return library.useSafariExtensions ? library.extensions.filter { !catalogued.contains($0.id) && matches($0.name) } : []
    }

    /// Everything the arrow keys move through, in reading order.
    private var order: [LibraryItem] {
        packs.map { .pack($0.id) } + tools.map { .plugin($0.id) } + privacy.map { .plugin($0.id) }
            + verified.map { .verified($0.id) } + installed.map { .installed($0.id) }
    }

    var body: some View {
        Group {
            if let detail, let pack = LibraryCatalog.pack(detail) {
                PackDetail(pack: pack) { id in parentPack = pack.id; self.detail = id } back: { close() }
            } else if let detail, let plugin = LibraryCatalog.plugin(detail) {
                PluginDetail(plugin: plugin, backTitle: parentPack.flatMap { LibraryCatalog.pack($0)?.title } ?? "Library") {
                    self.detail = parentPack
                    parentPack = nil
                }
            } else {
                list
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $addingChrome) {
            AddChromeExtensionSheet(problem: problem) { link in fetch(link) } openStore: {
                addingChrome = false
                browser.newTab(url: URL(string: "https://chromewebstore.google.com"))
            } done: { addingChrome = false }
        }
        .sheet(item: $preview) { p in
            AddExtensionSheet(preview: p) { library.install(p); preview = nil } cancel: { preview = nil }
        }
    }

    private func close() {
        detail = nil
        parentPack = nil
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    ForEach(packs) { pack in
                        PackCard(pack: pack, isFocused: focused == .pack(pack.id)) { detail = pack.id }.id(LibraryItem.pack(pack.id))
                    }
                    pluginGrid(title: "Browsa Plugins", detail: "Made for Browsa.", plugins: tools)
                    pluginGrid(title: "Privacy", detail: "Built in, and on from the start.", plugins: privacy)
                    extensionsSection
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: focused) { _, item in
                guard let item else { return }
                withAnimation(Motion.snappy) { proxy.scrollTo(item, anchor: .center) }
            }
        }
        .onAppear {
            searchFocused = true
            keys.start { handle($0) }
        }
        .onDisappear { keys.stop() }
    }

    // MARK: Keyboard

    /// Arrows move through the page while you can still type in search, like Raycast. Space and
    /// Return act on the selection; Escape goes back to search.
    private func handle(_ event: NSEvent) -> Bool {
        guard detail == nil, !addingChrome, preview == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: return move(+1) == .handled                      // down
        case 126: return move(-1) == .handled                      // up
        case 124: return focused != nil && move(+1) == .handled    // right
        case 123: return focused != nil && move(-1) == .handled    // left
        case 49: return focused != nil && toggleFocused() == .handled   // space
        case 36, 76: return focused != nil && openFocused() == .handled // return
        case 53:                                                     // escape
            guard focused != nil else { return false }
            focused = nil
            searchFocused = true
            return true
        default:
            // Typing goes back to search.
            if focused != nil, let c = event.characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                focused = nil
                searchFocused = true
            }
            return false
        }
    }

    /// Down from the search field lands on the first item; up from the first goes back to search.
    private func move(_ step: Int) -> KeyPress.Result {
        let items = order
        guard !items.isEmpty else { return .ignored }
        guard let current = focused, let i = items.firstIndex(of: current) else {
            guard step > 0 else { return .ignored }
            focused = items[0]
            return .handled
        }
        let next = i + step
        if next < 0 {
            focused = nil
            searchFocused = true
            return .handled
        }
        focused = items[min(next, items.count - 1)]
        return .handled
    }

    private func toggleFocused() -> KeyPress.Result {
        switch focused {
        case .pack(let id):
            guard let pack = LibraryCatalog.packs.first(where: { $0.id == id }) else { return .ignored }
            let on = LibraryActions.isPackOn(pack, in: browser)
            LibraryActions.togglePack(pack, on: !on, in: browser)
        case .plugin(let id):
            withAnimation(Motion.snappy) { LibraryActions.set(id, on: !LibraryActions.isOn(id, in: browser), in: browser) }
        case .installed(let id):
            if let item = library.extensionCatalog.items.first(where: { $0.id == id }) { library.setExtension(id, enabled: !item.isEnabled) }
        case .verified(let id):
            if let v = LibraryCatalog.verified.first(where: { $0.id == id }) { fetch(v.storeURL.absoluteString) }
        case nil: return .ignored
        }
        return .handled
    }

    private func openFocused() -> KeyPress.Result {
        switch focused {
        case .plugin(let id), .pack(let id):
            detail = id
            return .handled
        default: break
        }
        return toggleFocused()
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(.system(size: 30, weight: .bold))
                Text("Add to Browsa: our own plugins, and extensions from the Chrome Web Store.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search plugins and extensions", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).frame(height: 38)
            .glassEffect(.regular, in: .capsule)
        }
    }

    @ViewBuilder private func pluginGrid(title: String, detail: String, plugins: [PluginInfo]) -> some View {
        if !plugins.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: title, detail: detail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(plugins) { p in
                        PluginCard(plugin: p, isFocused: focused == .plugin(p.id)) {
                            self.detail = p.id
                        }
                        .id(LibraryItem.plugin(p.id))
                    }
                }
            }
        }
    }

    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionTitle(title: "Extensions", detail: "From the Chrome Web Store.")
                Spacer()
                Button { problem = nil; addingChrome = true } label: { Label("Add Chrome Extension", systemImage: "plus") }
                    .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
            }
            if let problem, !addingChrome { Text(problem).font(.caption).foregroundStyle(.red) }
            if !verified.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verified to work in Browsa").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(verified) { v in
                            VerifiedCard(ext: v, isFocused: focused == .verified(v.id)) { fetch(v.storeURL.absoluteString) }
                                .id(LibraryItem.verified(v.id))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Added").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    if installed.isEmpty && safari.isEmpty {
                        Text(search.isEmpty ? "Nothing added yet." : "No added extensions match.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    ForEach(Array(installed.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 58) }
                        ExtensionRow(item: item, isFocused: focused == .installed(item.id)).id(LibraryItem.installed(item.id))
                    }
                    ForEach(Array(safari.enumerated()), id: \.element.id) { i, ext in
                        if i > 0 || !installed.isEmpty { Divider().padding(.leading, 58) }
                        SafariExtensionRow(ext: ext)
                    }
                }
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            }
            HStack(spacing: 14) {
                Button("Check for Updates") { Task { await library.updateExtensions(force: true) } }
                Button("Add Unpacked Folder…", action: pickFolder)
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    private func fetch(_ link: String) {
        problem = nil
        Task {
            do {
                let p = try await library.previewExtension(link: link.trimmingCharacters(in: .whitespacesAndNewlines))
                addingChrome = false
                preview = p
            } catch { problem = error.localizedDescription }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with a manifest.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { preview = try library.previewExtension(folder: url) }
        catch { problem = "That folder has no extension manifest." }
    }
}

/// A key monitor for the Library while it's on screen, in the key window only.
@MainActor
final class LibraryKeys {
    private var monitor: Any?
    /// The Library on screen, for SpikeBrowsa's harness, which hands keys straight to the window
    /// while it's in the background (past the monitor).
    private(set) static var current: ((NSEvent) -> Bool)?

    func start(_ handle: @escaping (NSEvent) -> Bool) {
        stop()
        Self.current = handle
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.isKeyWindow ?? true, event.window?.attachedSheet == nil else { return event }
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if monitor != nil { Self.current = nil }
        monitor = nil
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

/// A plugin's icon: a neutral glyph on Browsa's white (or black) base, with soft blurred colour at
/// its edges. Each plugin gets its own arrangement, led by its tint.
struct PluginIcon: View {
    let symbol: String
    let tint: Color
    let seed: Int
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme

    init(plugin: PluginInfo, size: CGFloat = 40) {
        symbol = plugin.symbol; tint = plugin.tint; self.size = size
        seed = plugin.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }
    init(symbol: String, tint: Color, seed: Int = 0, size: CGFloat = 40) {
        self.symbol = symbol; self.tint = tint; self.seed = seed; self.size = size
    }

    private static let palette: [Color] = [.orange, .yellow, .pink, .mint, .purple, .red, .teal]
    /// Corners and edges a blob can sit on, as unit offsets from the centre.
    private static let spots: [CGPoint] = [.init(x: -0.5, y: -0.5), .init(x: 0.5, y: 0.5), .init(x: 0.5, y: -0.5),
                                           .init(x: -0.5, y: 0.5), .init(x: 0, y: 0.6), .init(x: 0.6, y: 0)]

    private var blobs: [(Color, CGPoint)] {
        let second = Self.palette[seed % Self.palette.count]
        let third = Self.palette[(seed / 3 + 2) % Self.palette.count]
        return [(tint, Self.spots[seed % 4]),
                (second, Self.spots[(seed + 1) % Self.spots.count]),
                (third, Self.spots[(seed / 5 + 3) % Self.spots.count])]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            shape.fill(scheme == .dark ? Color.black : Color.white)
            ZStack {
                ForEach(Array(blobs.enumerated()), id: \.offset) { i, blob in
                    Circle().fill(blob.0)
                        .frame(width: size * (i == 0 ? 1.1 : 0.85), height: size * (i == 0 ? 1.1 : 0.85))
                        .offset(x: blob.1.x * size * 0.8, y: blob.1.y * size * 0.8)
                }
            }
            .blur(radius: size * 0.3)
            .opacity(scheme == .dark ? 0.32 : 0.24)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

/// The keyboard's ring, in the system accent like its focus ring.
private struct FocusRing: ViewModifier {
    let on: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-4)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: on)
    }
}

// MARK: - Cards

private struct PackCard: View {
    @Environment(Browser.self) private var browser
    let pack: PluginPack
    let isFocused: Bool
    let open: () -> Void
    @State private var hovering = false
    private var on: Bool { LibraryActions.isPackOn(pack, in: browser) }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            PackFan(pack: pack, size: 50)
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.title).font(.system(size: 18, weight: .semibold))
                Text(pack.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { on }, set: { LibraryActions.togglePack(pack, on: $0, in: browser) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(20)
        .background { ZStack { Color(nsColor: .textBackgroundColor); PackGlow(pack: pack) } }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 8 : 3, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .modifier(FocusRing(on: isFocused, radius: 20))
    }
}

/// A pack's plugins, fanned like a hand of cards.
private struct PackFan: View {
    let pack: PluginPack
    var size: CGFloat = 50

    var body: some View {
        ZStack {
            ForEach(Array(pack.plugins.compactMap { LibraryCatalog.plugin($0) }.enumerated()), id: \.element.id) { i, p in
                PluginIcon(plugin: p, size: size)
                    .rotationEffect(.degrees(Double(i - 1) * 9))
                    .offset(x: CGFloat(i - 1) * size * 0.55, y: i == 1 ? -size * 0.07 : size * 0.04)
                    .zIndex(i == 1 ? 1 : 0)
            }
        }
        .frame(width: size * 2.4, height: size * 1.5)
    }
}

/// The pack card's base: its plugins' colours, spread softly across the whole card.
private struct PackGlow: View {
    let pack: PluginPack
    var body: some View {
        GeometryReader { g in
            let tints = pack.plugins.compactMap { LibraryCatalog.plugin($0)?.tint }
            ZStack {
                ForEach(Array(tints.enumerated()), id: \.offset) { i, t in
                    Ellipse().fill(t)
                        .frame(width: g.size.width * 0.55, height: g.size.height * 1.4)
                        .position(x: g.size.width * (0.1 + CGFloat(i) * 0.4), y: g.size.height * (i.isMultiple(of: 2) ? 0.2 : 0.8))
                }
            }
            .blur(radius: 60)
            .opacity(0.13)
        }
    }
}

private struct PluginCard: View {
    @Environment(Browser.self) private var browser
    let plugin: PluginInfo
    let isFocused: Bool
    let open: () -> Void
    @State private var hovering = false
    private var on: Bool { LibraryActions.isOn(plugin.id, in: browser) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PluginIcon(plugin: plugin)
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { LibraryActions.set(plugin.id, on: $0, in: browser) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.title).font(.system(size: 15, weight: .semibold))
                Text(plugin.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 8 : 3, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .modifier(FocusRing(on: isFocused, radius: 16))
    }
}

private struct VerifiedCard: View {
    @Environment(Browser.self) private var browser
    let ext: VerifiedExtension
    let isFocused: Bool
    let add: () -> Void

    private var library: Library { browser.library }
    /// Added from the Chrome Web Store: the version we tested.
    private var added: Bool { library.extensionCatalog.items.contains { $0.source.key.lowercased().contains(ext.id) } }
    /// Running only as the Safari extension from its app, which can't reach the app from Browsa.
    private var safariOnly: Bool {
        !added && library.useSafariExtensions && library.extensions.contains { $0.name.localizedCaseInsensitiveContains(ext.name) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = ext.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
            } else {
                Text(String(ext.name.prefix(1)))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(ext.color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ext.name).font(.system(size: 15, weight: .semibold))
                Text(safariOnly ? "Using the Safari version, which can't unlock with the app." : ext.blurb)
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if added {
                Label("Added", systemImage: "checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Button(safariOnly ? "Use Chrome Version" : "Add", action: add)
                    .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .modifier(FocusRing(on: isFocused, radius: 14))
    }
}

/// A Safari extension from an app on this Mac. It comes and goes with the app and the
/// Safari setting, so there's nothing to turn off here.
private struct SafariExtensionRow: View {
    let ext: EngineExtension

    var body: some View {
        HStack(spacing: 12) {
            ExtensionIcon(image: ext.icon.map { NSImage(cgImage: $0, size: .zero) }, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(ext.name).font(.system(size: 13, weight: .medium))
                Text("Safari extension from its app · \(ext.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct ExtensionRow: View {
    @Environment(Browser.self) private var browser
    let item: InstalledExtension
    let isFocused: Bool
    private var library: Library { browser.library }
    private var isVerified: Bool { LibraryCatalog.verified.contains { item.source.key.lowercased().contains($0.id) } }

    var body: some View {
        HStack(spacing: 12) {
            let icon = library.extensions.first { $0.id == item.id }?.icon
            ExtensionIcon(image: icon.map { NSImage(cgImage: $0, size: .zero) }, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name).font(.system(size: 13, weight: .medium))
                    if isVerified {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                            .help("Verified to work in Browsa")
                    }
                }
                Text("\(item.source.label) · \(item.version)").font(.caption).foregroundStyle(.secondary)
                if let pending = item.pendingUpdate {
                    Button("Update to \(pending.version): it asks for more") { library.approveUpdate(id: item.id) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Spacer()
            Menu {
                Button("Remove \(item.name)", role: .destructive) { withAnimation(Motion.snappy) { library.removeExtension(id: item.id) } }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(.rect) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize()
            Toggle("", isOn: Binding(get: { item.isEnabled }, set: { library.setExtension(item.id, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isFocused ? Color.accentColor.opacity(0.12) : .clear)
    }
}

// MARK: - Add Chrome Extension

/// How to add any Chrome extension: go to the store, copy the link, paste it here. With an honest
/// note on support, since only verified ones are tested.
private struct AddChromeExtensionSheet: View {
    let problem: String?
    let add: (String) -> Void
    let openStore: () -> Void
    let done: () -> Void
    @State private var link = ""

    private var canAdd: Bool { !link.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                PluginIcon(symbol: "puzzlepiece.extension.fill", tint: .blue, seed: 4, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Chrome Extension").font(.system(size: 17, weight: .semibold))
                    Text("Most Chrome extensions run in Browsa.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Find the extension in the Chrome Web Store.") {
                    Button(action: openStore) { Label("Open the Chrome Web Store", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
                }
                step(2, "On its page, copy the address from the address bar.") { EmptyView() }
                step(3, "Paste it here.") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("https://chromewebstore.google.com/detail/…", text: $link)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(.primary.opacity(0.06), in: .capsule)
                                .onSubmit { if canAdd { add(link) } }
                            Button("Add") { add(link) }
                                .buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
                                .disabled(!canAdd)
                        }
                        if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Text("Tip: on an extension's page in Browsa, an Add to Browsa bar appears at the top, so you can skip the copying.")
                .font(.caption).foregroundStyle(.secondary)
            Label {
                Text("Browsa runs Chrome extensions on Apple's WebKit, through a compatibility layer. The ones marked Verified are tested by us. Others usually work, but some features may not: unlocking with a desktop app, developer tools panels, or anything that controls Chrome itself.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "info.circle") }
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.glass).controlSize(.large).buttonBorderShape(.capsule)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func step<Content: View>(_ n: Int, _ text: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.accentColor, in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 13))
                content()
            }
        }
    }
}

// MARK: - A plugin's page

/// Everything about one plugin: what it does, and a switch for each place it shows up.
private struct PluginDetail: View {
    @Environment(Browser.self) private var browser
    let plugin: PluginInfo
    var backTitle = "Library"
    let back: () -> Void
    private var workbench: Workbench { browser.library.workbench }
    private var on: Bool { LibraryActions.isOn(plugin.id, in: browser) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BackButton(title: backTitle, action: back)
                HStack(alignment: .center, spacing: 18) {
                    PluginIcon(plugin: plugin, size: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.title).font(.system(size: 26, weight: .bold))
                        Text(plugin.blurb).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { on }, set: { LibraryActions.set(plugin.id, on: $0, in: browser) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Text(plugin.about).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where it shows up").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Divider().padding(.leading, 44) }
                            row
                        }
                    }
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12, style: .continuous))
                    .disabled(!on)
                    .opacity(on ? 1 : 0.5)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var rows: [AnyView] {
        switch plugin.id {
        case "radar":
            return [
                row("sidebar.left", "Sidebar card", "Lights for each server, under your tabs.",
                    isOn: Binding(get: { workbench.sidebarToolIDs.contains("radar") }, set: { _ in workbench.toggleSidebar("radar") })),
                row("rectangle.righthalf.inset.filled", "Panel", "Every server by project, with Restart.", isOn: nil),
                commandsRow,
            ]
        case "notes":
            return [
                row("rectangle.righthalf.inset.filled", "Panel", "Notes on this page and across the site.", isOn: nil),
                row("cursorarrow.click.2", "Add Note on right-click", "In every page's menu.", isOn: nil),
                commandsRow,
            ]
        case "agents":
            return [
                row("rectangle.righthalf.inset.filled", "Panel", "What agents are doing, asks waiting for you, and Stop.", isOn: nil),
                row("network", "MCP server", "On this Mac only, at 127.0.0.1:\(AgentBridge.port).", isOn: Bindable(browser.library.agents).isEnabled),
                commandsRow,
            ]
        default:
            return [row("globe", "Every site", "Turn it off for one site from the site menu in the address bar.", isOn: nil)]
        }
    }

    private var commandsRow: AnyView {
        row("command", "⌘K commands", "Its rows in the command bar.",
            isOn: Binding(get: { workbench.showsCommands(plugin.id) }, set: { workbench.setShowsCommands(plugin.id, $0) }))
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, isOn: Binding<Bool>?) -> AnyView {
        AnyView(HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let isOn {
                Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            } else {
                Text("With the plugin").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10))
    }
}

private struct BackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "chevron.left") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
    }
}

// MARK: - A pack's page

/// A pack: what's in it, with a switch for the whole pack and one for each plugin.
private struct PackDetail: View {
    @Environment(Browser.self) private var browser
    let pack: PluginPack
    let open: (String) -> Void
    let back: () -> Void
    private var on: Bool { LibraryActions.isPackOn(pack, in: browser) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BackButton(title: "Library", action: back)
                HStack(alignment: .center, spacing: 18) {
                    PackFan(pack: pack, size: 62)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.title).font(.system(size: 26, weight: .bold))
                        Text(pack.blurb).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { on }, set: { LibraryActions.togglePack(pack, on: $0, in: browser) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Text(pack.about).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("In this pack").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(pack.plugins.compactMap { LibraryCatalog.plugin($0) }.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Divider().padding(.leading, 62) }
                            PackRow(plugin: p) { open(p.id) }
                        }
                    }
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PackRow: View {
    @Environment(Browser.self) private var browser
    let plugin: PluginInfo
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PluginIcon(plugin: plugin, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.title).font(.system(size: 13, weight: .medium))
                Text(plugin.blurb).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
            Toggle("", isOn: Binding(get: { LibraryActions.isOn(plugin.id, in: browser) },
                                     set: { LibraryActions.set(plugin.id, on: $0, in: browser) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}
