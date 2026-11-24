import Foundation

// Folders among a space's pinned tabs, like Arc's. `Space.pinned` stays the flat list of pinned
// tabs, so everything that only cares which tabs are pinned keeps working; `Space.pinnedLayout`
// says how they're arranged into folders. The two are reconciled on read: a tab pinned without a
// place in the layout gets one next to its neighbours, and a tab that's gone drops out.

/// A folder of pinned tabs. Folders can hold other folders.
public struct PinnedFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// Showing its contents in the sidebar.
    public var isOpen: Bool
    public var children: [PinnedNode]
    /// Set for a Live Folder, which fills itself from a feed or a GitHub search (`LiveFolders`).
    public var live: LiveSource?

    public init(id: UUID = UUID(), name: String, isOpen: Bool = true, children: [PinnedNode] = [],
                live: LiveSource? = nil) {
        self.id = id
        self.name = name
        self.isOpen = isOpen
        self.children = children
        self.live = live
    }
}

/// One entry in the pinned section: a pinned tab, by id, or a folder.
public enum PinnedNode: Codable, Equatable, Sendable, Identifiable {
    case tab(UUID)
    case folder(PinnedFolder)

    public var id: UUID {
        switch self {
        case .tab(let id): id
        case .folder(let f): f.id
        }
    }

    public var folder: PinnedFolder? { if case .folder(let f) = self { f } else { nil } }

    private enum CodingKeys: String, CodingKey { case tab, folder }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .tab) {
            self = .tab(id)
        } else {
            self = .folder(try c.decode(PinnedFolder.self, forKey: .folder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let id): try c.encode(id, forKey: .tab)
        case .folder(let f): try c.encode(f, forKey: .folder)
        }
    }
}

/// A line in the sidebar's pinned section, as laid out: a tab or a folder, at a depth.
public struct PinnedRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let isFolder: Bool
    /// The folders it sits in, outermost first. Its depth is how many.
    public let path: [UUID]
    /// For a folder: whether its contents show.
    public let isOpen: Bool
    public var depth: Int { path.count }
}

/// Where something lands among the pinned: in a folder (nil for the top level), at an index among
/// that folder's own children.
public struct PinnedPlace: Equatable, Sendable {
    public var parent: UUID?
    public var index: Int
    public init(parent: UUID?, index: Int) {
        self.parent = parent
        self.index = index
    }
}

/// Working on a pinned layout. Everything here is pure, so it's easy to test.
public enum PinnedOutline {
    /// The layout with every tab in `tabs` in it exactly once and nothing else. A tab missing from
    /// it goes just before the next tab in `tabs` that has a place, in that tab's folder, or at the
    /// end of the top level, so a tab pinned before another lands where it was put.
    public static func reconciled(_ layout: [PinnedNode], tabs: [UUID]) -> [PinnedNode] {
        let wanted = Set(tabs)
        var seen = Set<UUID>()
        func clean(_ nodes: [PinnedNode]) -> [PinnedNode] {
            nodes.compactMap { node in
                switch node {
                case .tab(let id):
                    return wanted.contains(id) && seen.insert(id).inserted ? node : nil
                case .folder(var f):
                    guard seen.insert(f.id).inserted else { return nil }
                    f.children = clean(f.children)
                    return .folder(f)
                }
            }
        }
        var out = clean(layout)
        let missing = tabs.enumerated().filter { !seen.contains($0.element) }
        guard !missing.isEmpty else { return out }
        var placed = seen
        // Last first, so each one can go before a missing tab placed just now.
        for (i, id) in missing.reversed() {
            let next = tabs[(i + 1)...].first { placed.contains($0) }
            if let next, let place = self.place(of: next, in: out) {
                out = inserting(.tab(id), at: place, in: out)
            } else {
                out.append(.tab(id))
            }
            placed.insert(id)
        }
        return out
    }

    /// Every tab id, in the order the sidebar shows them with every folder open.
    public static func tabIDs(_ layout: [PinnedNode]) -> [UUID] {
        layout.flatMap { node -> [UUID] in
            switch node {
            case .tab(let id): [id]
            case .folder(let f): tabIDs(f.children)
            }
        }
    }

    /// A folder, with the folders it sits in.
    public struct FolderEntry: Identifiable, Sendable {
        public let folder: PinnedFolder
        public let path: [UUID]
        public var id: UUID { folder.id }
    }

    /// Every folder, outermost first, with the folders it sits in.
    public static func folders(_ layout: [PinnedNode], path: [UUID] = []) -> [FolderEntry] {
        layout.flatMap { node -> [FolderEntry] in
            guard case .folder(let f) = node else { return [] }
            return [FolderEntry(folder: f, path: path)] + folders(f.children, path: path + [f.id])
        }
    }

    public static func folder(_ id: UUID, in layout: [PinnedNode]) -> PinnedFolder? {
        folders(layout).first { $0.folder.id == id }?.folder
    }

    /// The folders an entry sits in, outermost first, or nil when it isn't in the layout.
    public static func path(of id: UUID, in layout: [PinnedNode]) -> [UUID]? {
        for node in layout {
            if node.id == id { return [] }
            if case .folder(let f) = node, let inner = path(of: id, in: f.children) { return [f.id] + inner }
        }
        return nil
    }

    /// Where an entry is: its folder and its index there.
    public static func place(of id: UUID, in layout: [PinnedNode]) -> PinnedPlace? {
        if let i = layout.firstIndex(where: { $0.id == id }) { return PinnedPlace(parent: nil, index: i) }
        for case .folder(let f) in layout {
            if let i = f.children.firstIndex(where: { $0.id == id }) { return PinnedPlace(parent: f.id, index: i) }
            if let inner = place(of: id, in: f.children) { return inner }
        }
        return nil
    }

    /// The node with this id, wherever it is.
    public static func node(_ id: UUID, in layout: [PinnedNode]) -> PinnedNode? {
        for node in layout {
            if node.id == id { return node }
            if case .folder(let f) = node, let inner = self.node(id, in: f.children) { return inner }
        }
        return nil
    }

    /// The layout without the entry, and the entry (with what it holds).
    public static func removing(_ id: UUID, from layout: [PinnedNode]) -> ([PinnedNode], PinnedNode?) {
        var removed: PinnedNode?
        func walk(_ nodes: [PinnedNode]) -> [PinnedNode] {
            nodes.compactMap { node in
                if node.id == id { removed = node; return nil }
                guard case .folder(var f) = node else { return node }
                f.children = walk(f.children)
                return .folder(f)
            }
        }
        let out = walk(layout)
        return (out, removed)
    }

    /// The layout with `node` at `place`. A folder that isn't there means the top level's end.
    public static func inserting(_ node: PinnedNode, at place: PinnedPlace, in layout: [PinnedNode]) -> [PinnedNode] {
        guard let parent = place.parent else {
            var out = layout
            out.insert(node, at: min(max(place.index, 0), out.count))
            return out
        }
        var found = false
        func walk(_ nodes: [PinnedNode]) -> [PinnedNode] {
            nodes.map { n in
                guard case .folder(var f) = n else { return n }
                if f.id == parent {
                    f.children.insert(node, at: min(max(place.index, 0), f.children.count))
                    found = true
                } else {
                    f.children = walk(f.children)
                }
                return .folder(f)
            }
        }
        let out = walk(layout)
        return found ? out : layout + [node]
    }

    /// Moves an entry to `place`, which is counted with the entry already taken out. Moving a
    /// folder into itself, or into a folder inside it, leaves the layout as it was.
    public static func moving(_ id: UUID, to place: PinnedPlace, in layout: [PinnedNode]) -> [PinnedNode] {
        if let parent = place.parent, parent == id || (path(of: parent, in: layout) ?? []).contains(id) { return layout }
        let (without, node) = removing(id, from: layout)
        guard let node else { return layout }
        return inserting(node, at: place, in: without)
    }

    /// Changes one folder in place.
    public static func updating(_ id: UUID, in layout: [PinnedNode], _ change: (inout PinnedFolder) -> Void) -> [PinnedNode] {
        layout.map { node in
            guard case .folder(var f) = node else { return node }
            if f.id == id { change(&f) } else { f.children = updating(id, in: f.children, change) }
            return .folder(f)
        }
    }

    /// Takes a folder away and puts what it held where it was.
    public static func dissolving(_ id: UUID, in layout: [PinnedNode]) -> [PinnedNode] {
        layout.flatMap { node -> [PinnedNode] in
            guard case .folder(var f) = node else { return [node] }
            if f.id == id { return dissolving(id, in: f.children) }
            f.children = dissolving(id, in: f.children)
            return [.folder(f)]
        }
    }

    // MARK: Rows

    /// The pinned section's lines, top to bottom. A closed folder hides what it holds, except the
    /// tab you're on, so you can always see where you are (as Arc does). `hiding` leaves out an
    /// entry and everything in it, for the one being dragged.
    public static func rows(_ layout: [PinnedNode], selected: UUID? = nil, hiding: UUID? = nil) -> [PinnedRow] {
        var out: [PinnedRow] = []
        func walk(_ nodes: [PinnedNode], path: [UUID], shown: Bool) {
            for node in nodes where node.id != hiding {
                switch node {
                case .tab(let id):
                    if shown || id == selected { out.append(PinnedRow(id: id, isFolder: false, path: path, isOpen: false)) }
                case .folder(let f):
                    // A folder inside a closed one shows only if it leads to the tab you're on.
                    let leadsToSelected = selected.map { s in tabIDs(f.children).contains(s) } ?? false
                    guard shown || leadsToSelected else { continue }
                    out.append(PinnedRow(id: f.id, isFolder: true, path: path, isOpen: f.isOpen))
                    walk(f.children, path: path + [f.id], shown: shown && f.isOpen)
                }
            }
        }
        walk(layout, path: [], shown: true)
        return out
    }

    /// The depths a dropped entry can take between `rows[index - 1]` and `rows[index]`: no deeper
    /// than just inside the folder above, and no shallower than the line below.
    public static func depths(at index: Int, in rows: [PinnedRow]) -> ClosedRange<Int> {
        let above = index > 0 && index <= rows.count ? rows[index - 1] : nil
        let below = index < rows.count ? rows[index] : nil
        let low = below?.depth ?? 0
        var high = above.map { $0.isFolder && ($0.isOpen || below?.path.contains($0.id) == true) ? $0.depth + 1 : $0.depth } ?? 0
        high = max(high, low)
        return low...high
    }

    /// Where an entry dropped at `index` among `rows`, at `depth`, lands. `rows` and `layout` are
    /// both without the entry being dropped.
    public static func place(at index: Int, depth: Int, rows: [PinnedRow], layout: [PinnedNode]) -> PinnedPlace {
        let range = depths(at: index, in: rows)
        let depth = min(max(depth, range.lowerBound), range.upperBound)
        guard index > 0, index <= rows.count else { return PinnedPlace(parent: nil, index: 0) }
        let above = rows[index - 1]
        // Just inside the folder above, at its top.
        if depth == above.depth + 1 { return PinnedPlace(parent: above.id, index: 0) }
        // Otherwise after the entry above, or after the folder it sits in at that depth.
        let anchor = depth == above.depth ? above.id : above.path[depth]
        guard let at = place(of: anchor, in: layout) else { return PinnedPlace(parent: nil, index: layout.count) }
        return PinnedPlace(parent: at.parent, index: at.index + 1)
    }
}
