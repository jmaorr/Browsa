import SwiftUI
import BrowserCore
import BrowserEngine
import UniformTypeIdentifiers

/// The part of the sidebar that belongs to the current space. It slides out and the new space's
/// tabs cascade in when the space changes, and all of it stays clipped inside the sidebar.
struct SpaceTabs: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let space = browser.currentSpace
        let forward = browser.lastSpaceSwitch?.forward ?? true
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                // Spaces are named by their icon in the switcher below, so only a private space gets a
                // header, for its Close All. Otherwise a slim strip at the top takes drops to pin.
                if space.isPrivate {
                    SpaceHeader(space: space)
                        .padding(.bottom, 4)
                        .dropDestination(for: String.self) { items, _ in return drop(items, before: nil, pinned: true) }
                } else {
                    Color.clear.frame(height: 6)
                        .contentShape(.rect)
                        .dropDestination(for: String.self) { items, _ in return drop(items, before: nil, pinned: true) }
                }

                ForEach(Array(space.pinned.enumerated()), id: \.element.id) { i, tab in
                    TabRow(tab: tab, selected: tab.id == browser.selectedTabID(in: space))
                        .spaceCascade(index: i, spaceSwitch: browser.lastSpaceSwitch)
                }

                if !space.isPrivate {
                    TodayDivider(space: space)
                        .dropDestination(for: String.self) { items, _ in return drop(items, before: space.listedToday.first, pinned: false) }
                }

                NewTabRow()

                ForEach(Array(space.listedToday.enumerated()), id: \.element.id) { i, tab in
                    TabRow(tab: tab, selected: tab.id == browser.selectedTabID(in: space))
                        .spaceCascade(index: i + space.pinned.count + 1, spaceSwitch: browser.lastSpaceSwitch)
                }

                // Room to drop below the last tab.
                Color.clear.frame(height: 40)
                    .contentShape(.rect)
                    .dropDestination(for: String.self) { items, _ in return drop(items, before: nil, pinned: false) }
            }
            .padding(.horizontal, 10)
            .id(space.id)
            .transition(.spaceListChange(forward: forward))
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        // Tabs sliding between spaces never spill out of the sidebar.
        .clipped()
    }

    private func drop(_ items: [String], before target: BrowserTab?, pinned: Bool) -> Bool {
        guard let item = items.first, case .tab(let id)? = SidebarDrag(item),
              let tab = browser.spaces.flatMap(\.allTabs).first(where: { $0.id == id }) else { return false }
        withAnimation(Motion.snappy) { browser.move(tab, before: target, pinned: pinned) }
        return true
    }
}

private struct SpaceHeader: View {
    @Environment(Browser.self) private var browser
    let space: Space

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(space.name)
                .font(.system(size: 13, weight: .bold))
            Spacer()
            if space.isPrivate {
                Button("Close All") { withAnimation(Motion.spring) { browser.closePrivateSpace() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// The line between pinned and today, with Arc's "Clear" on hover.
private struct TodayDivider: View {
    @Environment(Browser.self) private var browser
    let space: Space
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
            if hovering, !space.listedToday.isEmpty {
                Button { withAnimation(Motion.spring) { browser.clearToday() } } label: {
                    Label("Clear", systemImage: "arrow.down").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .help("Close every Today tab in this space")
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
    }
}

private struct NewTabRow: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
            Text("New Tab")
            Spacer()
            Text("⌘T").font(.system(size: 11)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { browser.showCommandBar(.newTab) }
        .onHover { hovering = $0 }
        .help("New Tab (⌘T)")
        .contextMenu {
            Button("New Private Tab", systemImage: "eye.slash") { browser.run(command: "private") }
        }
    }
}

/// One tab in the sidebar.
struct TabRow: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                TabIcon(tab: tab, size: 16)
                    .opacity(tab.isLoading && tab.estimatedProgress < 0.5 ? 0.35 : 1)
                if tab.isLoading && tab.estimatedProgress < 0.5 {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if hovering {
                Button { withAnimation(Motion.snappy) { browser.close(tab) } } label: {
                    Image(systemName: tab.isPinned ? "minus" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.isPinned ? "Unload Tab (⌘W)" : "Close Tab (⌘W)")
                .transition(.opacity)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(SelectedFill()) : AnyShapeStyle(.primary.opacity(hovering ? 0.06 : 0)))
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .contentShape(.rect)
        .onTapGesture { browser.select(tab) }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .draggable(SidebarDrag.tab(tab.id).payload) {
            HStack(spacing: 8) {
                TabIcon(tab: tab, size: 16)
                Text(tab.displayTitle).lineLimit(1)
            }
            .padding(8)
            .frame(width: 220, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 9))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, case .tab(let id)? = SidebarDrag(item), id != tab.id,
                  let moving = browser.spaces.flatMap(\.allTabs).first(where: { $0.id == id }) else { return false }
            withAnimation(Motion.snappy) { browser.move(moving, before: tab, pinned: tab.isPinned) }
            return true
        }
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}

struct TabMenu: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab

    var body: some View {
        if !tab.isPrivate {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") {
                withAnimation(Motion.snappy) { browser.togglePinned(tab) }
            }
        }
        if let url = tab.url {
            Button(browser.isFavorite(url) ? "Already a Favourite" : "Add to Favourites", systemImage: "star") {
                withAnimation(Motion.snappy) { browser.addFavorite(url: url, title: tab.displayTitle) }
            }
            .disabled(browser.isFavorite(url))
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Duplicate Tab", systemImage: "plus.square.on.square") {
                browser.newTab(url: url, in: browser.space(containing: tab), source: .link)
            }
        }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { browser.openInNewWindow(tab) }
        if !tab.isPrivate, browser.regularSpaces.count > 1 {
            Menu("Move to Space") {
                ForEach(browser.regularSpaces.filter { $0.id != browser.space(containing: tab)?.id }) { s in
                    Button(s.name, systemImage: s.symbol) { withAnimation(Motion.spring) { browser.move(tab, to: s) } }
                }
            }
        }
        Divider()
        if !tab.isPinned {
            Button("Close Other Tabs") { withAnimation(Motion.spring) { browser.closeOtherTabs(than: tab) } }
        }
        Button(tab.isPinned ? "Unload Tab" : "Close Tab", systemImage: "xmark", role: .destructive) {
            withAnimation(Motion.snappy) { browser.close(tab) }
        }
    }
}

// MARK: - Downloads

struct DownloadsButton: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        let running = browser.downloads.filter { $0.status == .running }
        Button { browser.isDownloadsPresented.toggle() } label: {
            ZStack {
                if !running.isEmpty {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle().trim(from: 0, to: running.map(\.progress).reduce(0, +) / Double(running.count))
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 20, height: 20)
            .frame(width: 26, height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(browser.downloads.isEmpty ? 0.5 : 1)
        .help("Downloads (⌥⌘J)")
        .popover(isPresented: $browser.isDownloadsPresented, arrowEdge: .top) {
            DownloadsList()
                .environment(browser)
        }
    }
}

struct DownloadsList: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { browser.library.downloads.removeAll { $0.status != .running } }
                    .disabled(!browser.downloads.contains { $0.status != .running })
            }
            .padding(12)
            Divider()
            if browser.downloads.isEmpty {
                Text("Files you download appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(browser.downloads) { DownloadRow(item: $0) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

private struct DownloadRow: View {
    let item: EngineDownload

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.fileURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .data))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .running: ProgressView(value: item.progress).controlSize(.small)
                case .finished: Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.status == .running {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
            } else if let url = item.fileURL, item.status == .finished {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if let url = item.fileURL, item.status == .finished { NSWorkspace.shared.open(url) }
        }
    }
}
