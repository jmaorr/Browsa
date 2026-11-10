import SwiftUI
import AppKit
import BrowserCore
import Extensibility

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
}

/// An extension we've tested, from `verified-extensions.json`.
struct VerifiedExtension: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let category: String
    let tint: String
    let tested: String

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
              blurb: "Leave notes on any page, pinned to what they're about. Your agents read them and reply.",
              surfaces: ["Panel", "⌘K", "Agent tools"],
              about: "Highlight text or pick anything on a page to leave a note. Notes stay with the page, show as pins while the panel is open, and connected agents can read, reply to and resolve them."),
        .init(id: "agents", title: "Agents", symbol: AgentIdentity.symbol, tint: .orange,
              blurb: "Let Claude Code, Codex or Cursor use Browsa, in an Agent space you can watch.",
              surfaces: ["Panel", "⌘K", "MCP"],
              about: "Turns on Browsa's MCP server on this Mac. Agents open pages in their own Agent space, ask before touching your tabs, and stop when you press Stop."),
        .init(id: "radar", title: "Radar", symbol: "dot.radiowaves.left.and.right", tint: .green,
              blurb: "Your dev servers, one click away, and a page that waits when one stops.",
              surfaces: ["Sidebar", "Panel", "⌘K"],
              about: "Finds the dev servers running on this Mac, names them by project and branch, and reloads a tab by itself when its server comes back."),
        .init(id: "privacy-blocking", title: "Ad & Tracker Blocker", symbol: "hand.raised.fill", tint: .blue,
              blurb: "Blocks ads and trackers on every site, with your own exceptions.",
              surfaces: ["Every page"], kind: .privacy,
              about: "Uses well-known filter lists, updated in the background. Turn it off for a single site from the site menu in the address bar."),
        .init(id: "privacy-cookies", title: "Cookie Banner Decliner", symbol: "checkmark.shield.fill", tint: .indigo,
              blurb: "Says no to cookie banners for you, so they close themselves.",
              surfaces: ["Every page"], kind: .privacy,
              about: "Uses DuckDuckGo's open-source Autoconsent to pick the most private choice on cookie banners and dismiss them."),
        .init(id: "privacy-links", title: "Clean Links", symbol: "link", tint: .teal,
              blurb: "Strips tracking bits (utm_, fbclid and friends) from links you open.",
              surfaces: ["Every link"], kind: .privacy,
              about: "Removes known tracking parameters before a page loads, so sites can't follow you from link to link."),
    ]

    static var toolPlugins: [PluginInfo] { plugins.filter { $0.kind == .tool } }
    static var privacyPlugins: [PluginInfo] { plugins.filter { $0.kind == .privacy } }
    static func plugin(_ id: String) -> PluginInfo? { plugins.first { $0.id == id } }

    static let agentPack = PluginPack(
        id: "agent-pack", title: "Browsa Agent Pack",
        blurb: "Everything for building with an AI agent beside you: Radar finds your dev servers, Notes holds your feedback, and Agents lets Claude Code work through it while you watch.",
        plugins: ["radar", "notes", "agents"])

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
    static func setAgentPack(_ on: Bool, in browser: Browser) {
        for id in LibraryCatalog.agentPack.plugins { set(id, on: on, in: browser, announce: false) }
    }
}

// MARK: - Page

/// One thing the keyboard can land on, in page order.
enum LibraryItem: Hashable {
    case pack
    case plugin(String)
    case verified(String)
    case installed(String)
}

struct LibraryView: View {
    @Environment(Browser.self) private var browser
    @State private var search = ""
    @State private var detail: String?
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

    private var showsPack: Bool { matches(LibraryCatalog.agentPack.title, LibraryCatalog.agentPack.blurb, "agent", "pack") }
    private var tools: [PluginInfo] { LibraryCatalog.toolPlugins.filter { matches($0.title, $0.blurb) } }
    private var privacy: [PluginInfo] { LibraryCatalog.privacyPlugins.filter { matches($0.title, $0.blurb, "privacy") } }
    private var installed: [InstalledExtension] { library.extensionCatalog.items.filter { matches($0.name, $0.source.label) } }
    private var verified: [VerifiedExtension] {
        let have = library.extensionCatalog.items.map { $0.source.key.lowercased() }
        return LibraryCatalog.verified.filter { v in !have.contains { $0.contains(v.id) } && matches(v.name, v.blurb, v.category) }
    }

    /// Everything the arrow keys move through, in reading order.
    private var order: [LibraryItem] {
        (showsPack ? [.pack] : []) + tools.map { .plugin($0.id) } + privacy.map { .plugin($0.id) }
            + verified.map { .verified($0.id) } + installed.map { .installed($0.id) }
    }

    var body: some View {
        ZStack {
            if let detail, let plugin = LibraryCatalog.plugin(detail) {
                PluginDetail(plugin: plugin) { close() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
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
        withAnimation(Motion.snappy) { detail = nil }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if showsPack {
                        PackCard(pack: LibraryCatalog.agentPack, isFocused: focused == .pack).id(LibraryItem.pack)
                    }
                    pluginGrid(title: "Browsa Plugins", detail: "Made for Browsa. Turn off what you don't use.", plugins: tools)
                    pluginGrid(title: "Privacy", detail: "Built in and on from the start. Here's what each one does for you.", plugins: privacy)
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
        case .pack:
            let on = LibraryCatalog.agentPack.plugins.allSatisfy { LibraryActions.isOn($0, in: browser) }
            withAnimation(Motion.snappy) { LibraryActions.setAgentPack(!on, in: browser) }
            browser.showToast(on ? "Turned off the \(LibraryCatalog.agentPack.title)" : "Added the \(LibraryCatalog.agentPack.title)")
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
        if case .plugin(let id) = focused {
            withAnimation(Motion.snappy) { detail = id }
            return .handled
        }
        return toggleFocused()
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
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
                Text("↓ to browse").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                            withAnimation(Motion.snappy) { self.detail = p.id }
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
                SectionTitle(title: "Extensions", detail: "Chrome extensions, running on Browsa's WebKit engine.")
                Spacer()
                Button { problem = nil; addingChrome = true } label: { Label("Add Chrome Extension", systemImage: "plus") }
                    .buttonStyle(.glass)
            }
            if let problem, !addingChrome { Text(problem).font(.caption).foregroundStyle(.red) }
            if !verified.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Verified to work in Browsa", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
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
                    if installed.isEmpty {
                        Text(search.isEmpty ? "Nothing added yet." : "No added extensions match.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    ForEach(Array(installed.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 58) }
                        ExtensionRow(item: item, isFocused: focused == .installed(item.id)).id(LibraryItem.installed(item.id))
                    }
                }
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            }
            HStack(spacing: 14) {
                Button("Check for Updates") { Task { await library.updateExtensions(force: true) } }
                Button("Add Unpacked Folder…", action: pickFolder)
                Spacer()
                Toggle("Safari extensions from your apps (experimental)", isOn: Bindable(library).useSafariExtensions)
                    .toggleStyle(.checkbox)
                    .help("Loads Safari extensions bundled in apps on this Mac. Ones that talk to their app, like password managers, can't reach it from Browsa.")
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A plugin's icon: its symbol on a tinted rounded square, like an app icon.
struct PluginIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    init(plugin: PluginInfo, size: CGFloat = 40) { symbol = plugin.symbol; tint = plugin.tint; self.size = size }
    init(symbol: String, tint: Color, size: CGFloat = 40) { self.symbol = symbol; self.tint = tint; self.size = size }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: tint.opacity(0.3), radius: 3, y: 1)
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
    private var allOn: Bool { pack.plugins.allSatisfy { LibraryActions.isOn($0, in: browser) } }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            // The pack's plugins, fanned like a hand of cards.
            ZStack {
                ForEach(Array(pack.plugins.compactMap { LibraryCatalog.plugin($0) }.enumerated()), id: \.element.id) { i, p in
                    PluginIcon(plugin: p, size: 54)
                        .rotationEffect(.degrees(Double(i - 1) * 9))
                        .offset(x: CGFloat(i - 1) * 30, y: i == 1 ? -4 : 2)
                        .zIndex(i == 1 ? 1 : 0)
                }
            }
            .frame(width: 130, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(pack.title).font(.system(size: 19, weight: .semibold))
                    Text("Pack").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.primary.opacity(0.08), in: .capsule)
                }
                Text(pack.blurb).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if allOn {
                        Label("Added", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                        Button("Turn Off") { setAll(false) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button { setAll(true) } label: { Label("Add Pack", systemImage: "plus") }
                            .buttonStyle(.glassProminent).controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.12), Color.yellow.opacity(0.08), Color.green.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        .modifier(FocusRing(on: isFocused, radius: 20))
    }

    private func setAll(_ on: Bool) {
        withAnimation(Motion.snappy) { LibraryActions.setAgentPack(on, in: browser) }
        browser.showToast(on ? "Added the \(pack.title)" : "Turned off the \(pack.title)")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                PluginIcon(plugin: plugin)
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in withAnimation(Motion.snappy) { LibraryActions.set(plugin.id, on: v, in: browser) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text(plugin.title).font(.system(size: 15, weight: .semibold))
            Text(plugin.blurb).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(plugin.surfaces, id: \.self) { s in
                    Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.primary.opacity(0.06), in: .capsule)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .opacity(hovering || isFocused ? 1 : 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 8 : 3, y: 1)
        .opacity(on ? 1 : 0.72)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .modifier(FocusRing(on: isFocused, radius: 16))
    }
}

private struct VerifiedCard: View {
    let ext: VerifiedExtension
    let isFocused: Bool
    let add: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(ext.name.prefix(1)))
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ext.color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.system(size: 14, weight: .semibold))
                    Text(ext.category).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(.primary.opacity(0.06), in: .capsule)
                }
                Text(ext.blurb).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Add", action: add).buttonStyle(.glass).controlSize(.small)
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .modifier(FocusRing(on: isFocused, radius: 14))
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.name).font(.system(size: 13, weight: .medium))
                    if isVerified {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
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
                PluginIcon(symbol: "puzzlepiece.extension.fill", tint: .blue, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Chrome Extension").font(.system(size: 17, weight: .semibold))
                    Text("Most Chrome extensions run in Browsa.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Find the extension in the Chrome Web Store.") {
                    Button("Open the Chrome Web Store", action: openStore).buttonStyle(.link)
                }
                step(2, "On its page, copy the address from the address bar.") { EmptyView() }
                step(3, "Paste it here.") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("https://chromewebstore.google.com/detail/…", text: $link)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                                .onSubmit { if canAdd { add(link) } }
                            Button("Add") { add(link) }
                                .buttonStyle(.glassProminent)
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
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.cancelAction) }
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
    let back: () -> Void
    private var workbench: Workbench { browser.library.workbench }
    private var on: Bool { LibraryActions.isOn(plugin.id, in: browser) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: back) { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                HStack(alignment: .center, spacing: 18) {
                    PluginIcon(plugin: plugin, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.title).font(.system(size: 26, weight: .bold))
                        Text(plugin.blurb).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { on }, set: { v in withAnimation(Motion.snappy) { LibraryActions.set(plugin.id, on: v, in: browser) } }))
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
