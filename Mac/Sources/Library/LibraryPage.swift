import SwiftUI
import AppKit
import BrowserCore
import Extensibility

/// The Library: everything you can add to Browsa, in one native page in a tab. Browsa's own
/// plugins (Notes, Agents, Radar), the extensions you've added, and packs that switch on a set at
/// once. Search first, toggles everywhere, like Raycast's Store and Extensions settings in one.
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
/// from a manifest's `browsa` block.
struct PluginInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let blurb: String
    /// Where it shows up: "Panel", "Sidebar", "⌘K", "Agent tools".
    let surfaces: [String]
}

/// A set of plugins switched on together.
struct PluginPack: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let plugins: [String]
}

@MainActor
enum LibraryCatalog {
    static let plugins: [PluginInfo] = [
        .init(id: "notes", title: "Notes", symbol: "text.bubble.fill", tint: Color(red: 0.96, green: 0.71, blue: 0.04),
              blurb: "Leave notes on any page, pinned to what they're about. Your agents read them and reply.",
              surfaces: ["Panel", "⌘K", "Agent tools"]),
        .init(id: "agents", title: "Agents", symbol: AgentIdentity.symbol, tint: .orange,
              blurb: "Let Claude Code, Codex or Cursor use Browsa, in an Agent space you can watch.",
              surfaces: ["Panel", "⌘K", "MCP"]),
        .init(id: "radar", title: "Radar", symbol: "dot.radiowaves.left.and.right", tint: .green,
              blurb: "Your dev servers, one click away, and a page that waits when one stops.",
              surfaces: ["Sidebar", "Panel", "⌘K"]),
    ]

    static let agentPack = PluginPack(
        id: "agent-pack", title: "Browsa Agent Pack",
        blurb: "Everything for building with an AI agent beside you: Radar finds your dev servers, Notes holds your feedback, and Agents lets Claude Code work through it while you watch.",
        plugins: ["radar", "notes", "agents"])
}

// MARK: - Page

struct LibraryView: View {
    @Environment(Browser.self) private var browser
    @State private var search = ""
    @State private var link = ""
    @State private var preview: Library.ExtensionPreview?
    @State private var problem: String?
    @State private var working = false
    @FocusState private var searchFocused: Bool

    private var library: Library { browser.library }
    private var workbench: Workbench { library.workbench }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if matches(LibraryCatalog.agentPack.title, LibraryCatalog.agentPack.blurb, "agent", "pack") {
                    PackCard(pack: LibraryCatalog.agentPack)
                }
                pluginsSection
                extensionsSection
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $preview) { p in
            AddExtensionSheet(preview: p) { library.install(p); preview = nil; link = "" } cancel: { preview = nil }
        }
        .onAppear { searchFocused = true }
    }

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
            }
            .padding(.horizontal, 14).frame(height: 38)
            .glassEffect(.regular, in: .capsule)
        }
    }

    // MARK: Plugins

    private var pluginsSection: some View {
        let shown = LibraryCatalog.plugins.filter { matches($0.title, $0.blurb) }
        return Group {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Browsa Plugins", detail: "Made for Browsa. Turn off what you don't use.")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                        ForEach(shown) { PluginCard(plugin: $0) }
                    }
                }
            }
        }
    }

    // MARK: Extensions

    private var extensionsSection: some View {
        let items = library.extensionCatalog.items.filter { matches($0.name, $0.source.label) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Extensions", detail: "Chrome and Firefox extensions, and Safari ones from your apps.")
            if search.isEmpty {
                addRow
            }
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text(search.isEmpty ? "No extensions yet. Add one from the Chrome Web Store above." : "No extensions match.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, 58) }
                    ExtensionRow(item: item)
                }
                if search.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: "safari").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Safari extensions from your apps").font(.system(size: 13, weight: .medium))
                            Text("From apps on this Mac, like 1Password. Some can't reach their app from Browsa.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Bindable(library).useSafariExtensions).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Paste a Chrome Web Store or Firefox Add-ons link", text: $link)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 9, style: .continuous))
                    .onSubmit(fetch)
                Button(working ? "Getting…" : "Add", action: fetch)
                    .buttonStyle(.glassProminent)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || working)
                Menu {
                    Button("Browse the Chrome Web Store") { browser.newTab(url: URL(string: "https://chromewebstore.google.com")) }
                    Button("Add Unpacked Folder…", action: pickFolder)
                    Divider()
                    Button("Check for Updates") { Task { await library.updateExtensions(force: true) } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(.rect) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize()
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func fetch() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do { preview = try await library.previewExtension(link: link.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { problem = error.localizedDescription }
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
    let plugin: PluginInfo
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: plugin.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(plugin.tint.gradient, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: plugin.tint.opacity(0.3), radius: 3, y: 1)
    }
}

// MARK: - Cards

private struct PackCard: View {
    @Environment(Browser.self) private var browser
    let pack: PluginPack
    private var workbench: Workbench { browser.library.workbench }
    private var allOn: Bool { pack.plugins.allSatisfy { workbench.isEnabled($0) } }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            // The pack's plugins, fanned like a hand of cards.
            ZStack {
                ForEach(Array(pack.plugins.compactMap { id in LibraryCatalog.plugins.first { $0.id == id } }.enumerated()), id: \.element.id) { i, p in
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
                        Button("Turn Off") { withAnimation(Motion.snappy) { setAll(false) } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button { withAnimation(Motion.snappy) { setAll(true) } } label: {
                            Label("Add Pack", systemImage: "plus")
                        }
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
    }

    private func setAll(_ on: Bool) {
        for id in pack.plugins { LibraryActions.set(id, on: on, in: browser, announce: false) }
        browser.showToast(on ? "Added the \(pack.title)" : "Turned off the \(pack.title)")
    }
}

private struct PluginCard: View {
    @Environment(Browser.self) private var browser
    let plugin: PluginInfo
    @State private var hovering = false
    private var on: Bool { browser.library.workbench.isEnabled(plugin.id) }

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
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 8 : 3, y: 1)
        .opacity(on ? 1 : 0.7)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
    }
}

private struct ExtensionRow: View {
    @Environment(Browser.self) private var browser
    let item: InstalledExtension
    private var library: Library { browser.library }

    var body: some View {
        HStack(spacing: 12) {
            let icon = library.extensions.first { $0.id == item.id }?.icon
            ExtensionIcon(image: icon.map { NSImage(cgImage: $0, size: .zero) }, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium))
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
    }
}

// MARK: - Turning plugins on and off

@MainActor
enum LibraryActions {
    static func set(_ id: String, on: Bool, in browser: Browser, announce: Bool = true) {
        let library = browser.library
        library.workbench.setEnabled(id, on)
        switch id {
        case "agents":
            // Agents is the MCP endpoint itself: off means no agent can connect.
            library.agents.isEnabled = on
        case "radar":
            if on, !library.workbench.sidebarToolIDs.contains("radar") { library.workbench.toggleSidebar("radar") }
        default: break
        }
        if !on, browser.panel == id { browser.panel = nil }
        guard announce else { return }
        browser.showToast(on ? "\(LibraryCatalog.plugins.first { $0.id == id }?.title ?? id) is on" : "\(LibraryCatalog.plugins.first { $0.id == id }?.title ?? id) is off")
    }
}
