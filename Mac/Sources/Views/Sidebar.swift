import SwiftUI
import AppKit
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
                .introArrival(0)
            AddressPill()
                .padding(.horizontal, 10)
                .introArrival(1)
            FavoritesGrid()
                .padding(.horizontal, 10)
                .introArrival(2)
            SpaceTabs()
                .introArrival(3)
            ToolSections()
                .padding(.horizontal, 10)
                .introArrival(4)
            bottomRow
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .introArrival(5)
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
// MARK: - Address

/// The current page's address. Clicking it opens the command bar to edit it (Cmd-L). The favicon opens
/// the site menu; pinned extensions and the extensions menu sit at the right end.
struct AddressPill: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let tab = browser.currentTab
        let zoom = browser.currentZoom
        let isWelcome = Welcome.isWelcome(tab?.url)
        HStack(spacing: 8) {
            SiteMenu()
            Text(isWelcome ? "Welcome to Browsa" : tab?.url.map(URLNormalizer.displayHost) ?? "Search or enter address")
                .lineLimit(1)
                .foregroundStyle(tab?.url == nil ? .secondary : .primary)
            Spacer(minLength: 0)
            if hovering, tab?.url != nil, !isWelcome {
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
            ForEach(browser.library.pinnedExtensions) { ext in
                PinnedExtensionIcon(ext: ext, pillHovered: hovering)
            }
            ExtensionsMenu()
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

/// A view an extension's popup can be anchored to, for SwiftUI controls that have no NSView of their own.
@MainActor final class PopupAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: PopupAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

extension Browser {
    /// Runs an extension's toolbar action on the current page; its popup opens at `anchor`.
    func runExtension(_ ext: EngineExtension, anchor: NSView?) {
        engine.performAction(extensionID: ext.id, for: currentController?.page, anchor: anchor)
    }
}

/// The site's favicon, as a button: this site's settings, then what each extension can do here. The menu is
/// AppKit's, popped up at the icon (a SwiftUI Menu draws its label image at full size).
private struct SiteMenu: View {
    @Environment(Browser.self) private var browser
    @State private var anchor = PopupAnchor()

    var body: some View {
        let tab = browser.currentTab
        Button(action: showMenu) {
            Group {
                if tab?.isPrivate == true {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary)
                } else if let url = tab?.url, url.scheme == "http" || url.scheme == "https" {
                    FaviconView(url: url, size: 16)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(AnchorView(anchor: anchor))
        .help("Site settings and extensions")
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let actions = MenuActions()
        let menu = NSMenu()
        let page = browser.currentController?.page
        if let url = browser.currentTab?.url, let host = url.host() {
            menu.addItem(.sectionHeader(title: URLNormalizer.displayHost(url)))
            let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
            zoom.badge = NSMenuItemBadge(string: "\(Int((browser.currentZoom * 100).rounded()))%")
            let zoomMenu = NSMenu()
            zoomMenu.addItem(actions.item("Zoom In") { browser.zoom(1) })
            zoomMenu.addItem(actions.item("Zoom Out") { browser.zoom(-1) })
            zoomMenu.addItem(actions.item("Actual Size") { browser.zoom(0) })
            zoom.submenu = zoomMenu
            menu.addItem(zoom)
            let reader = actions.item(browser.isReaderShowing ? "Hide Reader" : "Reader") { browser.toggleReader() }
            reader.keyEquivalent = "r"
            reader.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(reader)
            let media = NSMenuItem(title: "Camera and Microphone", action: nil, keyEquivalent: "")
            let current = mediaPermission(host)
            media.badge = NSMenuItemBadge(string: current == nil ? "Ask" : current! ? "Allow" : "Block")
            let mediaMenu = NSMenu()
            for (title, value) in [("Ask", Bool?.none), ("Allow", Bool?.some(true)), ("Block", Bool?.some(false))] {
                let item = actions.item(title) { setMediaPermission(host, value) }
                item.state = current == value ? .on : .off
                mediaMenu.addItem(item)
            }
            media.submenu = mediaMenu
            menu.addItem(media)
        }
        let exts = browser.library.actionExtensions
        if !exts.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for ext in exts {
                let state = browser.library.actionState(ext, for: page)
                let item = actions.item(title(ext, state)) { browser.runExtension(ext, anchor: view) }
                item.image = extensionImage(ext, state)
                item.isEnabled = state?.isEnabled != false
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 6 : -6), in: view)
        withExtendedLifetime(actions) {}
    }

    /// "Fill with 1Password" for a password manager, the extension's name otherwise, with its badge.
    private func title(_ ext: EngineExtension, _ state: EngineActionState?) -> String {
        let managers = ["1password", "bitwarden", "lastpass", "dashlane", "proton pass", "keeper", "nordpass", "roboform", "enpass"]
        let name = state?.label.isEmpty == false ? state!.label : ext.name
        let base = managers.contains { ext.name.lowercased().contains($0) } ? "Fill with \(name)" : name
        guard let badge = state?.badgeText, !badge.isEmpty else { return base }
        return Int(badge) != nil ? "\(base): \(badge) blocked" : "\(base) (\(badge))"
    }

    /// Saved answers for camera and microphone on this site: nil means Browsa asks.
    private func mediaPermission(_ host: String) -> Bool? {
        let saved = browser.library.settings.sitePermissions[host] ?? [:]
        return saved[EnginePermission.cameraAndMicrophone.rawValue] ?? saved[EnginePermission.camera.rawValue] ?? saved[EnginePermission.microphone.rawValue]
    }

    private func setMediaPermission(_ host: String, _ value: Bool?) {
        for p in [EnginePermission.camera, .microphone, .cameraAndMicrophone] {
            browser.library.settings.sitePermissions[host, default: [:]][p.rawValue] = value
        }
    }
}

/// Closures behind NSMenu items.
@MainActor final class MenuActions: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count - 1
        return item
    }

    @objc private func run(_ item: NSMenuItem) { actions[item.tag]() }
}

/// An extension's icon at menu size.
@MainActor func extensionImage(_ ext: EngineExtension, _ state: EngineActionState?) -> NSImage {
    if let icon = state?.icon ?? ext.icon { return NSImage(cgImage: icon, size: NSSize(width: 16, height: 16)) }
    return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: ext.name) ?? NSImage()
}

/// An extension's icon for this page: its action's current icon, or its own.
private struct ExtensionIconImage: View {
    let ext: EngineExtension
    let state: EngineActionState?

    var body: some View {
        if let icon = state?.icon ?? ext.icon {
            Image(decorative: icon, scale: CGFloat(icon.width) / 16)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "puzzlepiece.extension")
        }
    }
}

/// A pinned extension in the address pill. Greyscale at rest; in colour while the pointer is over the
/// pill, or when the extension has something for this page (shown with a dot).
private struct PinnedExtensionIcon: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    let ext: EngineExtension
    let pillHovered: Bool
    @State private var anchor = PopupAnchor()

    var body: some View {
        let state = browser.library.actionState(ext, for: browser.currentController?.page)
        let live = state?.hasSomethingForPage == true
        ExtensionIconImage(ext: ext, state: state)
            .saturation(pillHovered || live ? 1 : 0)
            .opacity(pillHovered || live ? 1 : 0.55)
            .overlay(alignment: .bottomTrailing) {
                if live {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            .background(AnchorView(anchor: anchor))
            .contentShape(.rect)
            .onTapGesture { browser.runExtension(ext, anchor: anchor.view) }
            .contextMenu {
                Button("Unpin") { browser.library.setPinned(ext, false) }
                Button("Manage Extensions…") {
                    Preferences.settingsTab = "extensions"
                    openSettings()
                }
            }
            .help(state?.badgeText.isEmpty == false ? "\(ext.name): \(state!.badgeText)" : ext.name)
            .animation(Motion.snappy, value: pillHovered)
    }
}

/// Every extension with a toolbar button, in a popover: click a row to run it, click its pin to keep it
/// in the address pill, or manage extensions.
private struct ExtensionsMenu: View {
    @Environment(Browser.self) private var browser
    @State private var anchor = PopupAnchor()
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(AnchorView(anchor: anchor))
        .help("Extensions")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ExtensionsList(anchor: anchor) { isPresented = false }
                .environment(browser)
        }
    }
}

private struct ExtensionsList: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    let anchor: PopupAnchor
    let dismiss: () -> Void

    var body: some View {
        let library = browser.library
        VStack(alignment: .leading, spacing: 2) {
            if library.actionExtensions.isEmpty {
                Text("No extensions with a toolbar button yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(library.actionExtensions, id: \.id) { ext in
                ExtensionRow(ext: ext, pinned: library.isPinned(ext)) {
                    dismiss()
                    // Let the popover close first, so the extension's own popup opens at the pill.
                    DispatchQueue.main.async { browser.runExtension(ext, anchor: anchor.view) }
                } togglePin: {
                    withAnimation(Motion.snappy) { library.setPinned(ext, !library.isPinned(ext)) }
                }
            }
            Divider().padding(.vertical, 4)
            ExtensionFooterButton(title: "Manage Extensions…", symbol: "gearshape") {
                dismiss()
                Preferences.settingsTab = "extensions"
                openSettings()
            }
        }
        .padding(6)
        .frame(width: 260)
    }
}

private struct ExtensionRow: View {
    let ext: EngineExtension
    let pinned: Bool
    let run: () -> Void
    let togglePin: () -> Void
    @State private var hovering = false
    @State private var pinHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ExtensionIconImage(ext: ext, state: nil)
            Text(ext.name).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(45))
                    .frame(width: 24, height: 24)
                    .background(pinHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .opacity(pinned || hovering ? 1 : 0)
            .onHover { pinHovering = $0 }
            .help(pinned ? "Unpin from Address Bar" : "Pin to Address Bar")
            .accessibilityLabel(pinned ? "Unpin \(ext.name)" : "Pin \(ext.name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: run)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ExtensionFooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { hovering = $0 }
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

