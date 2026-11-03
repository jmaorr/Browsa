import SwiftUI
import BrowserCore
import Suggest

/// Arc-style sidebar: address field, pinned tabs grid, "+ New Tab", today's tabs, space switcher.
struct SidebarView: View {
    @Environment(BrowserState.self) private var browser
    /// Off when the bottom bar has the address.
    var showsAddress = true

    private let pinnedColumns = [GridItem(.adaptive(minimum: 56), spacing: 8)]
    /// How far a tab travels on arriving from another space. A short move, faded in, reads as one
    /// sweep with the list leaving instead of each row crossing the whole sidebar.
    private static let cascadeDistance: CGFloat = 140

    var body: some View {
        let space = browser.currentSpace
        VStack(alignment: .leading, spacing: 12) {
            if showsAddress {
                addressButton
                    .padding(.horizontal, 12)
            }

            spaceTabs(space)

            spaceSwitcher
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
    }

    /// Everything that changes with the space.
    private func spaceTabs(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !space.pinned.isEmpty {
                LazyVGrid(columns: pinnedColumns, spacing: 8) {
                    ForEach(Array(space.pinned.enumerated()), id: \.element.id) { i, tab in
                        pinnedTile(tab, selected: tab.id == space.selectedTabID)
                            .spaceCascade(index: i, distance: Self.cascadeDistance, spaceSwitch: browser.lastSpaceSwitch)
                    }
                }
                // Leaves with the list below, rather than vanishing while the rows slide away.
                .id(space.id)
                .transition(.spaceListChange(forward: browser.lastSpaceSwitch?.forward ?? true))
            }

            Button { browser.presentNewTab() } label: {
                Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu { NewTabMenu() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            List {
                ForEach(space.today) { tab in
                    TabRow(tab: tab, selected: tab.id == space.selectedTabID)
                        .spaceCascade(index: (space.today.firstIndex { $0.id == tab.id } ?? 0) + space.pinned.count,
                                      distance: Self.cascadeDistance, spaceSwitch: browser.lastSpaceSwitch)
                        .listRowInsets(.init(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // Its own tint: the app-wide .primary is white in dark mode, under white text.
                        .swipeActions { Button("Close", systemImage: "xmark", role: .destructive) { browser.close(tab) }.tint(.red) }
                }
                .onMove { from, to in space.today.move(fromOffsets: from, toOffset: to); browser.scheduleSave() }
            }
            .listStyle(.plain)
            // Pinned, so the selected tab's taller background never changes the spacing between tabs.
            .environment(\.defaultMinListRowHeight, TabRow.pitch)
            .scrollContentBackground(.hidden)
            // A new list per space, so its rows arrive fresh and the old ones leave together.
            .id(space.id)
            .transition(.spaceListChange(forward: browser.lastSpaceSwitch?.forward ?? true))
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        // Tabs moving between spaces stay inside the sidebar, and run right up to its edge.
        .clipped()
    }

    private var addressButton: some View {
        Button { browser.presentAddressEditor() } label: {
            HStack(spacing: 8) {
                if browser.currentTab?.isPrivate == true {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityLabel("Private")
                }
                if let url = browser.currentTab?.url {
                    FaviconView(url: url, size: 18)
                    Text(URLNormalizer.displayHost(url)).lineLimit(1)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search or enter address").lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let tab = browser.currentTab, tab.url != nil { ReloadButton(tab: tab) }
            }
            .font(.callout)
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .overlay(alignment: .bottom) { if let tab = browser.currentTab { LoadingStrip(tab: tab) } }
            .clipShape(.capsule)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func pinnedTile(_ tab: BrowserTab, selected: Bool) -> some View {
        Button { browser.select(tab) } label: {
            Group {
                if let url = tab.url { FaviconView(url: url, size: 28) }
                else { Image(systemName: "globe") }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.thinMaterial),
                        in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { TabMenu(tab: tab) }
    }

    private var spaceSwitcher: some View {
        HStack(spacing: 14) {
            ForEach(browser.spaces) { s in
                Button { withAnimation(Motion.spring) { browser.selectSpace(s) } } label: {
                    Image(systemName: s.symbol)
                        .foregroundStyle(s.id == browser.selectedSpaceID ? .primary : .secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.name)
                .contextMenu {
                    if s.isPrivate {
                        Button("Close Private Tabs", systemImage: "xmark", role: .destructive) {
                            withAnimation(Motion.spring) { browser.closePrivateSpace() }
                        }
                    }
                }
            }
            Spacer()
            Button("Settings", systemImage: "gearshape") { browser.isSettingsPresented = true }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

struct TabRow: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab
    let selected: Bool

    /// One tab's slot in the list: the same spacing as before.
    static let pitch: CGFloat = 44
    /// The selected background fills the slot, apart from a point above and below.
    private static let height = pitch - 2

    var body: some View {
        Button { browser.select(tab) } label: {
            HStack(spacing: 10) {
                if let url = tab.url { FaviconView(url: url, size: 20) }
                else { Image(systemName: "globe").frame(width: 20) }
                Text(tab.displayTitle).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: Self.height)
            .background(selected ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { TabMenu(tab: tab) }
    }
}

struct TabMenu: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab

    var body: some View {
        if !tab.isPrivate {
            Button(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin") {
                browser.togglePinned(tab)
            }
        }
        if let url = tab.url {
            Button(browser.isFavorite(url) ? "Already a Favourite" : "Add to Favourites", systemImage: "star") {
                browser.addFavorite(url: url, title: tab.displayTitle)
            }
            .disabled(browser.isFavorite(url))
            ShareLink(item: url)
        }
        Button("Close", systemImage: "xmark", role: .destructive) { browser.close(tab) }
    }
}
