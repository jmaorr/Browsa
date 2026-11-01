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
                    ForEach(space.pinned) { tab in pinnedTile(tab, selected: tab.id == space.selectedTabID) }
                }
            }

            Divider()

            Button { browser.presentNewTab(from: NewTabSource.sidebar.rawValue) } label: {
                Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .newTabZoomSource(.sidebar)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            List {
                ForEach(space.today) { tab in
                    TabRow(tab: tab, selected: tab.id == space.selectedTabID)
                        .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions { Button("Close", systemImage: "xmark", role: .destructive) { browser.close(tab) } }
                }
                .onMove { from, to in space.today.move(fromOffsets: from, toOffset: to); browser.scheduleSave() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            spaceSwitcher
        }
        .padding(12)
    }

    private var addressButton: some View {
        Button { browser.presentAddressEditor(from: NewTabSource.sidebarAddress.rawValue) } label: {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(browser.currentTab?.url.map(URLNormalizer.displayHost) ?? "Search or enter address")
                    .lineLimit(1)
                    .foregroundStyle(browser.currentTab?.url == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                // Room for the copy button, which sits on top so it gets its own taps.
                Color.clear.frame(width: browser.currentTab?.url == nil ? 0 : 24, height: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .newTabZoomSource(.sidebarAddress)
        .overlay(alignment: .trailing) {
            if browser.currentTab?.url != nil {
                // One tap to copy, without opening the editor.
                CopyLinkButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .padding(.trailing, 2)
            }
        }
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
                Button { withAnimation(.smooth) { browser.selectSpace(s) } } label: {
                    Image(systemName: s.symbol)
                        .foregroundStyle(s.id == browser.selectedSpaceID ? SpacePalette.color(s.colorIndex) : .secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.name)
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
                if selected {
                    Button("Close", systemImage: "xmark") { browser.close(tab) }
                        .labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                }
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
        Button(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin") {
            browser.togglePinned(tab)
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
