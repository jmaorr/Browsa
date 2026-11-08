import SwiftUI
import BrowserCore
import BrowserEngine
import Suggest

/// Arc-style sidebar: navigation, address, favourites, then the current space's pinned and today
/// tabs, and the space switcher at the bottom.
struct Sidebar: View {
    @Environment(Browser.self) private var browser
    /// Floating over the page (undocked), rather than beside it.
    var isFloating = false

    var body: some View {
        VStack(spacing: 10) {
            topRow
            AddressPill()
                .padding(.horizontal, 10)
            FavoritesGrid()
                .padding(.horizontal, 10)
            SpaceTabs()
            ToolSections()
                .padding(.horizontal, 10)
            bottomRow
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .background { SpaceSwipeArea { browser.selectAdjacentSpace($0) } }
    }

    /// Room for the traffic lights, then back, forward and reload, like Arc.
    private var topRow: some View {
        HStack(spacing: 2) {
            // The traffic lights sit here when docked. Floating, they're hidden.
            Spacer(minLength: isFloating ? 0 : 76)
            SidebarIconButton(symbol: "sidebar.left", help: browser.isSidebarDocked ? "Hide Sidebar (⌘S)" : "Keep Sidebar Open (⌘S)") {
                withAnimation(Motion.dock) { browser.toggleSidebar() }
            }
            SidebarIconButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: browser.currentTab?.canGoBack == true) { browser.goBack() }
            SidebarIconButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: browser.currentTab?.canGoForward == true) { browser.goForward() }
            if browser.currentTab?.isLoading == true {
                SidebarIconButton(symbol: "xmark", help: "Stop (⌘.)") { browser.stopLoading() }
            } else {
                SidebarIconButton(symbol: "arrow.clockwise", help: "Reload (⌘R)", enabled: browser.currentTab?.url != nil) { browser.reload() }
            }
            Spacer(minLength: 0)
            ExtensionButtons()
            SidebarIconButton(symbol: "sidebar.right", help: browser.panel == nil ? "Show Panel (⌥⌘S)" : "Hide Panel (⌥⌘S)") {
                browser.togglePanel()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: isFloating ? 36 : 28)
        .padding(.top, isFloating ? 0 : 1)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
    }

    private var bottomRow: some View {
        HStack(spacing: 4) {
            DownloadsButton()
            Spacer(minLength: 0)
            SpaceSwitcher()
            Spacer(minLength: 0)
            Menu {
                Button("New Space", systemImage: "plus.rectangle.on.rectangle") { withAnimation(Motion.spring) { browser.addSpace() } }
                Button("New Private Tab", systemImage: "eye.slash") { browser.run(command: "private") }
                Divider()
                Button("Archived Tabs…", systemImage: "archivebox") { browser.isArchivePresented = true }
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Space and more")
        }
        .frame(height: 30)
    }
}

/// Small borderless icon button for the sidebar's top and bottom rows.
struct SidebarIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Extensions

/// A button per extension with a toolbar action. Clicking runs the action; a popup opens under the button.
struct ExtensionButtons: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ForEach(browser.library.extensions.filter(\.hasAction)) { ext in
            ExtensionButton(ext: ext) { anchor in
                browser.engine.performAction(extensionID: ext.id, for: browser.currentController?.page, anchor: anchor)
            }
            .frame(width: 28, height: 26)
            .help(ext.name)
        }
    }
}

/// An AppKit button, so the popup has a view to anchor to.
private struct ExtensionButton: NSViewRepresentable {
    let ext: EngineExtension
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    private var image: NSImage {
        if let icon = ext.icon { return NSImage(cgImage: icon, size: NSSize(width: 16, height: 16)) }
        return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.name) ?? NSImage()
    }

    @MainActor final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func click(_ sender: NSButton) { action(sender) }
    }
}

// MARK: - Address

/// The current page's address. Clicking it opens the command bar to edit it (Cmd-L).
struct AddressPill: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let tab = browser.currentTab
        let zoom = browser.currentZoom
        HStack(spacing: 8) {
            if tab?.isPrivate == true {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
            } else if let url = tab?.url, url.scheme == "https" {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary.opacity(0.55))
            }
            Text(tab?.url.map(URLNormalizer.displayHost) ?? "Search or enter address")
                .lineLimit(1)
                .foregroundStyle(tab?.url == nil ? .secondary : .primary)
            Spacer(minLength: 0)
            if hovering, tab?.url != nil {
                Button { browser.copyCurrentLink() } label: { Image(systemName: "link") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy Link (⇧⌘C)")
                    .transition(.opacity)
            }
            if abs(zoom - 1) > 0.01 {
                Button("\(Int((zoom * 100).rounded()))%") { browser.zoom(0) }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Actual Size (⌘0)")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.primary.opacity(hovering ? 0.09 : 0.06), in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { browser.showCommandBar(.editCurrent) }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .help("Search or enter address (⌘L)")
    }
}

// MARK: - Favourites

/// Favourites, shared by every space: a grid of site icons, like Arc's top row.
struct FavoritesGrid: View {
    @Environment(Browser.self) private var browser
    private let columns = [GridItem(.adaptive(minimum: 48, maximum: 80), spacing: 6)]

    var body: some View {
        let favorites = browser.sortedFavorites
        if !favorites.isEmpty {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(favorites) { fav in
                    FavoriteTile(favorite: fav)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                return dropOnGrid(items, before: nil)
            }
        }
    }

    private func dropOnGrid(_ items: [String], before target: Favorite?) -> Bool {
        guard let item = items.first, let drag = SidebarDrag(item) else { return false }
        switch drag {
        case .favorite(let id):
            guard let fav = browser.favorites.first(where: { $0.id == id }) else { return false }
            withAnimation(Motion.snappy) { browser.moveFavorite(fav, before: target) }
        case .tab(let id):
            guard let tab = browser.spaces.flatMap(\.allTabs).first(where: { $0.id == id }), let url = tab.url else { return false }
            withAnimation(Motion.snappy) { browser.addFavorite(url: url, title: tab.displayTitle) }
        }
        return true
    }
}

struct FavoriteTile: View {
    @Environment(Browser.self) private var browser
    let favorite: Favorite
    @State private var hovering = false

    private var isCurrent: Bool {
        browser.currentTab?.url.map(URLNormalizer.key(for:)) == URLNormalizer.key(for: favorite.url)
    }

    var body: some View {
        FaviconView(url: favorite.url, size: 20, chip: true, letter: favorite.customName ?? favorite.title)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(isCurrent ? AnyShapeStyle(SelectedFill()) : AnyShapeStyle(.primary.opacity(hovering ? 0.09 : 0.05)),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(isCurrent ? 0.08 : 0), radius: 2, y: 1)
            .contentShape(.rect)
            .onTapGesture { browser.open(favorite) }
            .onHover { hovering = $0 }
            .help(favorite.displayName)
            .draggable(SidebarDrag.favorite(favorite.id).payload)
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first, case .favorite(let id)? = SidebarDrag(item),
                      let fav = browser.favorites.first(where: { $0.id == id }) else { return false }
                withAnimation(Motion.snappy) { browser.moveFavorite(fav, before: favorite) }
                return true
            }
            .contextMenu {
                Button("Open in New Tab", systemImage: "plus.square.on.square") { browser.newTab(url: favorite.url, source: .bookmark) }
                Button("Copy Link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(favorite.url.absoluteString, forType: .string)
                }
                Divider()
                Button("Remove from Favourites", systemImage: "star.slash", role: .destructive) {
                    withAnimation(Motion.snappy) { browser.removeFavorite(favorite) }
                }
            }
    }
}

/// What's being dragged around the sidebar, as a plain string so it works with `draggable`.
enum SidebarDrag {
    case tab(UUID)
    case favorite(UUID)

    var payload: String {
        switch self {
        case .tab(let id): "browsa-tab:\(id.uuidString)"
        case .favorite(let id): "browsa-fav:\(id.uuidString)"
        }
    }

    init?(_ string: String) {
        if string.hasPrefix("browsa-tab:"), let id = UUID(uuidString: String(string.dropFirst(11))) { self = .tab(id) }
        else if string.hasPrefix("browsa-fav:"), let id = UUID(uuidString: String(string.dropFirst(11))) { self = .favorite(id) }
        else { return nil }
    }
}

// MARK: - Space switcher

struct SpaceSwitcher: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { i, s in
                let selected = s.id == browser.selectedSpaceID
                Button { withAnimation(Motion.spring) { browser.selectSpace(s) } } label: {
                    Image(systemName: selected ? s.symbol : "circle.fill")
                        .font(.system(size: selected ? 12 : 6))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .tertiary)
                .help(i < 9 ? "\(s.name) (⌃\(i + 1))" : s.name)
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, case .tab(let id)? = SidebarDrag(item),
                          let tab = browser.spaces.flatMap(\.allTabs).first(where: { $0.id == id }) else { return false }
                    withAnimation(Motion.spring) { browser.move(tab, to: s) }
                    return true
                }
                .contextMenu {
                    if s.isPrivate {
                        Button("Close Private Tabs", systemImage: "xmark", role: .destructive) {
                            withAnimation(Motion.spring) { browser.closePrivateSpace() }
                        }
                    } else {
                        SettingsLink { Label("Edit Spaces…", systemImage: "pencil") }
                        if browser.regularSpaces.count > 1 {
                            Button("Delete \(s.name)", systemImage: "trash", role: .destructive) {
                                withAnimation(Motion.spring) { browser.deleteSpace(s) }
                            }
                        }
                    }
                }
            }
        }
        .animation(Motion.snappy, value: browser.selectedSpaceID)
    }
}

// MARK: - Tool sections

/// Sections tools put under the tabs (Radar's dev servers, say). Each one folds away, and
/// right-click removes it. The order is the user's.
struct ToolSections: View {
    @Environment(Browser.self) private var browser
    @AppStorage("collapsedToolSections") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        let tools = browser.library.workbench.sidebarTools
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Button { toggle(tool.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tool.symbol).font(.system(size: 10, weight: .semibold))
                                Text(tool.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                if tool.stage == .preview { PreviewBadge() }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(collapsed.contains(tool.id) ? -90 : 0))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if tool.panel != nil { Button("Open in Panel") { browser.showPanel(tool.id) } }
                            Button("Remove from Sidebar") { browser.library.workbench.toggleSidebar(tool.id) }
                        }
                        if !collapsed.contains(tool.id), let view = tool.sidebar {
                            view().transition(.opacity)
                        }
                    }
                }
            }
            .animation(Motion.snappy, value: collapsedRaw)
        }
    }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }
}

