import SwiftUI
import BrowserCore
import BrowserEngine

/// The part of the sidebar that belongs to the current space. It slides out and the new space's
/// tabs cascade in when the space changes, and all of it stays clipped inside the sidebar.
struct SpaceTabs: View {
    @Environment(Browser.self) private var browser
    @Environment(SidebarDragging.self) private var dragging
    @State private var scroll = ScrollPosition()
    @State private var listFrame: CGRect = .zero
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0

    /// A row in a section: a tab, or the gap a dragged tab would land in.
    private struct Slot: Identifiable {
        let id: String
        /// Nil for the gap.
        let tab: BrowserTab?
        /// The tab being dragged, folded to nothing where it was. Its row has to stay in the view
        /// tree, or SwiftUI drops the drag gesture that's carrying it.
        var collapsed = false
        static let gap = Slot(id: "gap", tab: nil)
        @MainActor static func tab(_ tab: BrowserTab, collapsed: Bool = false) -> Slot {
            Slot(id: tab.id.uuidString, tab: tab, collapsed: collapsed)
        }
    }

    /// The section's tabs with a gap where the dragged one would land, and the dragged one folded
    /// away at its old place.
    private func slots(_ tabs: [BrowserTab], pinned: Bool, gapAllowed: Bool = true) -> [Slot] {
        var slots = tabs.filter { !dragging.isLifted($0.id) }.map { Slot.tab($0) }
        if gapAllowed, let target = dragging.target, pinned ? target.isPinned : target.isToday {
            slots.insert(.gap, at: min(target.index, slots.count))
        }
        if let i = tabs.firstIndex(where: { dragging.isLifted($0.id) }) {
            slots.insert(.tab(tabs[i], collapsed: true), at: min(i, slots.count))
        }
        return slots
    }

    var body: some View {
        let space = browser.currentSpace
        let forward = browser.lastSpaceSwitch?.forward ?? true
        // Dragging with nothing else pinned: a zone to drop on stands in for the Pinned section.
        let pinZone = dragging.lift != nil && !space.isPrivate && !space.pinned.contains { !dragging.isLifted($0.id) }
        let pinned = slots(space.pinned, pinned: true, gapAllowed: !pinZone)
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
                if pinned.contains(where: { !$0.collapsed }) {
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
        // However the space changes (a swipe, a key, a click), the old list slides out as the new one
        // slides in. Swipes and keys change it outside any animation, so the old list used to vanish.
        .animation(Motion.spring, value: space.id)
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentOffset.y, max(0, g.contentSize.height - g.containerSize.height)]
        } action: { _, v in offset = v[0]; maxOffset = v[1] }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: { listFrame = $0 }
        // Dragging near the top or bottom edge scrolls the list, so any slot can be reached.
        .task(id: dragging.lift != nil) {
            guard dragging.lift != nil else { return }
            while !Task.isCancelled {
                let speed = dragging.autoscrollSpeed(in: listFrame)
                if speed != 0, maxOffset > 0 {
                    let next = min(max(offset + speed, 0), maxOffset)
                    if next != offset {
                        scroll.scrollTo(y: next)
                        dragging.retarget?()
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .frame(maxHeight: .infinity)
        // Tabs sliding between spaces never spill out of the sidebar.
        .clipped()
    }

    @ViewBuilder private func row(_ slot: Slot, in space: Space) -> some View {
        if let tab = slot.tab {
            DraggableTabRow(tab: tab, space: space, collapsed: slot.collapsed)
        } else {
            SunkenSlot(cornerRadius: 9, active: true)
                .frame(height: 34)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                    dragging.gapFrame = $0
                }
                .transition(.opacity)
        }
    }
}

/// A tab row that can be picked up and dragged around the sidebar.
private struct DraggableTabRow: View {
    @Environment(Browser.self) private var browser
    @Environment(SidebarDragging.self) private var dragging
    let tab: BrowserTab
    let space: Space
    /// Being dragged: folded to nothing, but kept so its gesture lives on.
    let collapsed: Bool
    @GestureState private var held = false

    var body: some View {
        TabRow(tab: tab, selected: tab.id == browser.selectedTabID(in: space))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDragging.coordinateSpace)) } action: {
                if !collapsed { dragging.rowFrames[tab.id] = $0 }
            }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarDragging.coordinateSpace))
                .updating($held) { _, held, _ in held = true }
                .onChanged { dragging.changed(tab, $0, in: space, browser: browser) }
                .onEnded { _ in dragging.ended(tab, in: space, browser: browser) })
            // A drag the system cancels (no onEnded) still puts the tab down.
            .onChange(of: held) { _, now in
                if !now, dragging.isLifted(tab.id) { dragging.ended(tab, in: space, browser: browser) }
            }
            .frame(height: collapsed ? 0 : nil, alignment: .top)
            .opacity(collapsed ? 0 : 1)
            .clipped()
            // Cancels the stack's spacing, so the folded row takes no room at all.
            .padding(.bottom, collapsed ? -2 : 0)
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
        .background { SunkenSlot(cornerRadius: 10, active: targeted) }
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
        .help(Shortcuts.shared.help("New Tab", .newTab))
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
                .help(Shortcuts.shared.help(tab.isPinned ? "Unload Tab" : "Close Tab", .close))
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
        .help(Shortcuts.shared.help(showing ? "Hide Downloads" : "Downloads", .downloads))
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
