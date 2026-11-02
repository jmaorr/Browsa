import SwiftUI
import BrowserCore
import Suggest

/// Arc-style sidebar: address field, pinned tabs grid, "+ New Tab", today's tabs, space switcher.
struct SidebarView: View {
    @Environment(BrowserState.self) private var browser

    private let pinnedColumns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        let space = browser.currentSpace
        VStack(alignment: .leading, spacing: 12) {
            addressButton

            if !space.pinned.isEmpty {
                LazyVGrid(columns: pinnedColumns, spacing: 8) {
                    ForEach(Array(space.pinned.enumerated()), id: \.element.id) { i, tab in
                        pinnedTile(tab, selected: tab.id == space.selectedTabID)
                            .spaceCascade(index: i, distance: 240, spaceSwitch: browser.lastSpaceSwitch)
                    }
                }
            }

            Divider()

            Button { browser.presentNewTab(from: NewTabSource.sidebar.rawValue) } label: {
                Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .newTabZoomSource(.sidebar)
            .contextMenu { NewTabMenu() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            List {
                ForEach(space.today) { tab in
                    TabRow(tab: tab, selected: tab.id == space.selectedTabID)
                        .spaceCascade(index: (space.today.firstIndex { $0.id == tab.id } ?? 0) + space.pinned.count,
                                      distance: 240, spaceSwitch: browser.lastSpaceSwitch)
                        .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // Its own tint: the app-wide .primary is white in dark mode, under white text.
                        .swipeActions { Button("Close", systemImage: "xmark", role: .destructive) { browser.close(tab) }.tint(.red) }
                }
                .onMove { from, to in space.today.move(fromOffsets: from, toOffset: to); browser.scheduleSave() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // A new list per space, so its rows arrive fresh and the old ones leave together.
            .id(space.id)
            .transition(.spaceListChange(forward: browser.lastSpaceSwitch?.forward ?? true))
            .frame(maxHeight: .infinity)
            .clipped()

            spaceSwitcher
        }
        .padding(12)
    }

    private var addressButton: some View {
        Button { browser.presentAddressEditor(from: NewTabSource.sidebarAddress.rawValue) } label: {
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
        .newTabZoomSource(.sidebarAddress)
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

    var body: some View {
        Button { browser.select(tab) } label: {
            HStack(spacing: 10) {
                if let url = tab.url { FaviconView(url: url, size: 20) }
                else { Image(systemName: "globe").frame(width: 20) }
                Text(tab.displayTitle).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
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
