import SwiftUI
import BrowserCore
import BrowserEngine
import UniformTypeIdentifiers

/// The part of the sidebar that belongs to the current space. It slides out and the new space's
/// tabs cascade in when the space changes, and all of it stays clipped inside the sidebar.
struct SpaceTabs: View {
    @Environment(Browser.self) private var browser
    @Environment(SidebarDragging.self) private var dragging

    /// A row in a section: a tab, or the gap a dragged tab would land in.
    private struct Slot: Identifiable {
        let id: String
        /// Nil for the gap.
        let tab: BrowserTab?
        static let gap = Slot(id: "gap", tab: nil)
        @MainActor static func tab(_ tab: BrowserTab) -> Slot { Slot(id: tab.id.uuidString, tab: tab) }
    }

    /// The section's tabs without the one being dragged, with a gap where it would land.
    private func slots(_ tabs: [BrowserTab], pinned: Bool) -> [Slot] {
        var slots = tabs.filter { !dragging.isLifted($0.id) }.map(Slot.tab)
        if let target = dragging.target, target.isPinned == pinned {
            slots.insert(.gap, at: min(target.index, slots.count))
        }
        return slots
    }

    var body: some View {
        let space = browser.currentSpace
        let forward = browser.lastSpaceSwitch?.forward ?? true
        // Dragging with nothing else pinned: a zone to drop on stands in for the Pinned section.
        let pinZone = dragging.lift != nil && !space.isPrivate && !space.pinned.contains { !dragging.isLifted($0.id) }
        let pinned = pinZone ? [] : slots(space.pinned, pinned: true)
        let today = slots(space.listedToday, pinned: false)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                // Spaces are named by their icon in the switcher below, so only a private space gets a header.
                if space.isPrivate {
                    SpaceHeader(space: space)
                        .padding(.bottom, 4)
                } else {
                    Color.clear.frame(height: 6)
                }

                // Dragging with nothing pinned yet: somewhere to pin, and what pinning means.
                if pinZone {
                    PinDropZone(targeted: dragging.target?.isPinned == true,
                                landing: dragging.settling && dragging.target?.isPinned == true)
                        // As tall as a pinned row and the air under it, so nothing jumps when it lands.
                        .frame(height: 44)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                            dragging.pinZoneFrame = $0
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }

                ForEach(Array(pinned.enumerated()), id: \.element.id) { i, slot in
                    row(slot, in: space)
                        .spaceCascade(index: i, spaceSwitch: browser.lastSpaceSwitch)
                }

                // A little air between pinned and Today, rather than a rule.
                if !pinned.isEmpty {
                    Color.clear.frame(height: 8)
                }

                NewTabRow(space: space)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                        dragging.newTabFrame = $0
                    }

                ForEach(Array(today.enumerated()), id: \.element.id) { i, slot in
                    row(slot, in: space)
                        .spaceCascade(index: i + pinned.count + 1, spaceSwitch: browser.lastSpaceSwitch)
                }

                Color.clear.frame(height: 40)
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

    @ViewBuilder private func row(_ slot: Slot, in space: Space) -> some View {
        if let tab = slot.tab {
            TabRow(tab: tab, selected: tab.id == browser.selectedTabID(in: space))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                    dragging.rowFrames[tab.id] = $0
                }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarDragging.coordinateSpace))
                    .onChanged { dragging.changed(tab, $0, in: space) }
                    .onEnded { _ in dragging.ended(tab, in: space, browser: browser) })
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(0.04))
                .frame(height: 34)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                    dragging.gapFrame = $0
                }
                .transition(.opacity)
        }
    }
}

/// Shown while a tab is dragged and nothing is pinned yet: drop above New Tab to pin.
private struct PinDropZone: View {
    var targeted: Bool
    /// The tab is settling into the zone: the words step aside for it.
    var landing = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.primary.opacity(0.06)), in: .circle)
            VStack(alignment: .leading, spacing: 0) {
                Text("Drop here to pin")
                    .font(.system(size: 12, weight: .semibold))
                Text("Pinned tabs are never cleared.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(landing ? 0 : 1)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.07)) : AnyShapeStyle(.primary.opacity(0.035)),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.primary.opacity(0.14)),
                          style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 3])))
        .animation(Motion.snappy, value: targeted)
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

/// New Tab, with Clear on hover: closes this space's Today tabs except the one you're on.
private struct NewTabRow: View {
    @Environment(Browser.self) private var browser
    let space: Space
    @State private var hovering = false
    @State private var clearHovering = false

    private var canClear: Bool {
        space.listedToday.contains { $0.id != browser.currentTab?.id }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
            Text("New Tab")
            Spacer()
            if hovering, canClear, !space.isPrivate {
                Button { withAnimation(Motion.spring) { browser.clearToday() } } label: {
                    Text("Clear Tabs")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(.primary.opacity(clearHovering ? 0.12 : 0.07), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .onHover { clearHovering = $0 }
                .help("Close the other Today tabs in this space")
                .transition(.opacity)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { browser.showCommandBar(.newTab) }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .help("New Tab (⌘T)")
    }
}

/// One tab in the sidebar.
struct TabRow: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    /// Drawn under the pointer while dragged.
    var isLifted = false
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
            let notes = openNoteCount(tab.url, in: browser.library)
            if notes > 0 {
                // Stays put and slides left when the close button comes in on hover. A click opens
                // this tab's notes.
                Button {
                    browser.select(tab)
                    if browser.panel != "notes" { browser.showPanel("notes") }
                } label: {
                    Text(verbatim: "\(notes)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(NoteColor.ink)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(NoteColor.pin.opacity(0.85), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(notes == 1 ? "1 open note. Click to show it." : "\(notes) open notes. Click to show them.")
                .transition(.scale.combined(with: .opacity))
            }
            if hovering, !isLifted {
                Button { withAnimation(Motion.snappy) { browser.close(tab) } } label: {
                    Image(systemName: tab.isPinned ? "minus" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.isPinned ? "Unload Tab (⌘W)" : "Close Tab (⌘W)")
                .transition(.move(edge: .trailing).combined(with: .opacity))
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

/// The sidebar's downloads button: a ring while files download. Opens Downloads in the right panel.
struct DownloadsButton: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let running = browser.downloads.filter { $0.status == .running }
        let showing = browser.panel == "downloads"
        Button { browser.showPanel("downloads", toggles: true) } label: {
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
            .frame(width: 28, height: 26)
            .background(showing || hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(showing ? .primary : .secondary)
        .opacity(browser.downloads.isEmpty && !showing ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(showing ? "Hide Downloads (⌥⌘J)" : "Downloads (⌥⌘J)")
    }
}

/// Downloads, as a panel tool beside the page: newest first, full height, with Finder actions.
struct DownloadsPanel: View {
    @Environment(Browser.self) private var browser
    @State private var selection: UUID?

    var body: some View {
        let downloads = browser.downloads
        VStack(spacing: 0) {
            if downloads.isEmpty {
                PanelEmptyState(title: "No Downloads", symbol: "arrow.down.circle",
                                message: "Files you download in Browsa appear here, newest first.") {
                    Button("Open Downloads Folder", action: openFolder)
                }
            } else {
                List(selection: $selection) {
                    ForEach(downloads.reversed()) { item in
                        DownloadRow(item: item).tag(item.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand { remove(selection) }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let item = downloads.first(where: { $0.id == id }) { menu(for: item) }
                } primaryAction: { ids in
                    if let id = ids.first, let item = downloads.first(where: { $0.id == id }) { open(item) }
                }
            }
            if !downloads.isEmpty {
                Divider().opacity(0.5)
                HStack {
                    Button("Open Downloads Folder", systemImage: "folder", action: openFolder)
                    Spacer()
                    Button("Clear") { browser.library.downloads.removeAll { $0.status != .running } }
                        .disabled(!downloads.contains { $0.status != .running })
                        .help("Remove finished downloads from the list. The files stay.")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
        }
    }

    private func openFolder() {
        if let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(dir)
        }
    }

    @ViewBuilder private func menu(for item: EngineDownload) -> some View {
        if item.status == .running {
            Button("Cancel Download", systemImage: "xmark") { item.cancel() }
        } else {
            Button("Open", systemImage: "arrow.up.forward.app") { open(item) }.disabled(item.status != .finished)
            Button("Show in Finder", systemImage: "folder") {
                if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(item.fileURL == nil || item.status != .finished)
        }
        if let source = item.sourceURL {
            Button("Copy Download Address", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if item.status != .running {
            Divider()
            Button("Remove from List", systemImage: "minus.circle") { remove(item.id) }
        }
    }

    private func open(_ item: EngineDownload) {
        if let url = item.fileURL, item.status == .finished { NSWorkspace.shared.open(url) }
    }

    private func remove(_ id: UUID?) {
        guard let id else { return }
        browser.library.downloads.removeAll { $0.id == id && $0.status != .running }
    }
}

private struct DownloadRow: View {
    let item: EngineDownload

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.fileURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .data))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                switch item.status {
                case .running: ProgressView(value: item.progress).controlSize(.small)
                case .finished: Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .padding(.vertical, 4)
    }

    /// "example.com · 2:14 PM", where the file came from and when.
    private var detail: String {
        let time = item.startedAt.formatted(date: .omitted, time: .shortened)
        guard let host = item.sourceURL?.host() else { return time }
        let short = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "\(short) · \(time)"
    }
}
