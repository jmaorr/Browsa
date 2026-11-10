import SwiftUI
import BrowserCore
import BrowserEngine
import Suggest

/// A tab being dragged around the sidebar. The sidebar owns the whole drag rather than handing it
/// to the system: the row lifts and follows the pointer, the rows around it slide apart to show
/// where it will land, and on release it settles into that gap. Everything stays inside the sidebar.
@Observable @MainActor
final class SidebarDragging {
    /// Where a dragged tab would land: a slot among the other tabs of a section, or among the
    /// favourites, where it becomes the favourite's own tab.
    enum Target: Equatable {
        case pinned(Int)
        case today(Int)
        case favourite(Int)
        /// Another space, by dropping on its dot in the switcher.
        case space(UUID)

        var isPinned: Bool { if case .pinned = self { true } else { false } }
        var isToday: Bool { if case .today = self { true } else { false } }
        var isFavourite: Bool { if case .favourite = self { true } else { false } }
        var index: Int { switch self { case .pinned(let i), .today(let i), .favourite(let i): i; case .space: 0 } }
    }

    struct Lift {
        /// A tab's id, or a favourite's when `isFavourite`.
        let tabID: UUID
        var isFavourite = false
        /// Where it came from, for a drag that ends nowhere useful.
        let origin: Target
        /// From the row's top-left corner to the pointer, so the row doesn't jump to the pointer.
        let grab: CGSize
        let size: CGSize
    }

    static let coordinateSpace = "sidebar"

    private(set) var lift: Lift?
    /// The pointer, in the sidebar's coordinate space.
    private(set) var location: CGPoint = .zero
    private(set) var target: Target?
    /// Released and gliding into its gap; the list is about to commit the move.
    private(set) var settling = false
    /// Dropped on another space: shrinking into its dot.
    private(set) var leaving = false
    /// The size of a favourite tile, which the lifted tab shrinks to over the favourites.
    var tileSize = CGSize(width: 56, height: 50)
    /// The favourites in order, and whether the dragged tab may join them; set as the drag starts.
    private var favouriteOrder: [UUID] = []
    private var favouritesAllowed = false

    // Layout, reported by the views in the sidebar's coordinate space.
    var rowFrames: [UUID: CGRect] = [:]
    var newTabFrame: CGRect = .zero
    var gapFrame: CGRect = .zero
    /// The favourites grid, or the zone standing in for an empty one. Zero while neither shows.
    var favouritesFrame: CGRect = .zero
    var tileFrames: [UUID: CGRect] = [:]
    /// The switcher's dots, by space.
    var spaceFrames: [UUID: CGRect] = [:]
    /// The "Drop here to pin" zone, while it shows.
    var pinZoneFrame: CGRect = .zero
    /// The sidebar's top-left corner in the window, for tools that think in window points.
    var originInWindow: CGPoint = .zero

    #if SPIKE
    /// The most recently shown sidebar, for SpikeBrowsa's drag hook.
    static weak var latest: SidebarDragging?

    /// Drags the tab under `from` to `to` (window points) as a person would, over `duration`.
    func spikeDrag(from: CGPoint, to: CGPoint, duration: Double, hold: Double = 0, browser: Browser) async -> Bool {
        let a = CGPoint(x: from.x - originInWindow.x, y: from.y - originInWindow.y)
        let b = CGPoint(x: to.x - originInWindow.x, y: to.y - originInWindow.y)
        let space = browser.currentSpace
        let steps = max(2, Int(duration * 60))
        if let fav = browser.favorites.first(where: { tileFrames[$0.id]?.contains(a) == true }) {
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                changed(fav, from: a, to: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), in: space, browser: browser)
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(150))
            ended(fav, in: space, browser: browser)
            return true
        }
        guard let tab = space.allTabs.first(where: { rowFrames[$0.id]?.contains(a) == true }) else { return false }
        for i in 0...steps {
            // Ease in and out, like a hand.
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            changed(tab, from: a, to: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), in: space, browser: browser)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .seconds(hold))
        try? await Task.sleep(for: .milliseconds(150))
        ended(tab, in: space, browser: browser)
        return true
    }
    #endif

    func isLifted(_ id: UUID) -> Bool { lift.map { !$0.isFavourite && $0.tabID == id } ?? false }
    func isLiftedFavourite(_ id: UUID) -> Bool { lift.map { $0.isFavourite && $0.tabID == id } ?? false }

    /// The top-left corner the lifted row is drawn at.
    var liftedOrigin: CGPoint {
        guard let lift else { return .zero }
        return CGPoint(x: location.x - lift.grab.width, y: location.y - lift.grab.height)
    }

    // MARK: Gesture

    func changed(_ tab: BrowserTab, _ value: DragGesture.Value, in space: Space, browser: Browser) {
        changed(tab, from: value.startLocation, to: value.location, in: space, browser: browser)
    }

    func changed(_ tab: BrowserTab, from start: CGPoint, to point: CGPoint, in space: Space, browser: Browser) {
        guard !settling else { return }
        if lift == nil {
            guard let frame = rowFrames[tab.id] else { return }
            favouriteOrder = browser.sortedFavorites.map(\.id)
            favouritesAllowed = canFavourite(tab, browser: browser)
            let origin = slot(of: tab, in: space)
            location = point
            withAnimation(Motion.snappy) {
                lift = Lift(tabID: tab.id, origin: origin,
                            grab: CGSize(width: start.x - frame.minX, height: start.y - frame.minY),
                            size: frame.size)
                target = origin
            }
            return
        }
        location = point
        retarget = { [weak self] in self?.update(tab, in: space) }
        update(tab, in: space)
    }

    private func update(_ tab: BrowserTab, in space: Space) {
        guard lift != nil, !settling else { return }
        let next = resolveTarget(for: tab, in: space)
        if next != target { withAnimation(Motion.snappy) { target = next } }
    }

    /// Picks the slot again with the pointer where it is, after the list scrolled under it.
    private(set) var retarget: (() -> Void)?

    /// How fast the tab list should scroll, in points per frame, with the pointer near its top or
    /// bottom edge during a drag: faster the closer it gets. Zero elsewhere.
    func autoscrollSpeed(in list: CGRect) -> CGFloat {
        guard lift != nil, !settling, list.height > 0, list.minX - 20 ... list.maxX + 20 ~= location.x else { return 0 }
        let band: CGFloat = 36
        if location.y > list.minY, location.y < list.minY + band { return -8 * (1 - (location.y - list.minY) / band) - 1 }
        if location.y < list.maxY, location.y > list.maxY - band { return 8 * (1 - (list.maxY - location.y) / band) + 1 }
        return 0
    }

    // MARK: Favourites

    /// A favourite picked up: it can move among the favourites, or come down into the list as a
    /// tab, pinned or not, and stop being a favourite.
    func changed(_ fav: Favorite, from start: CGPoint, to point: CGPoint, in space: Space, browser: Browser) {
        guard !settling else { return }
        if lift == nil {
            guard let frame = tileFrames[fav.id] else { return }
            let order = browser.sortedFavorites.map(\.id)
            favouriteOrder = order.filter { $0 != fav.id }
            favouritesAllowed = true
            tileSize = frame.size
            let origin = Target.favourite(order.firstIndex(of: fav.id) ?? 0)
            location = point
            // As a row it lines up with the list, held where the pointer is across it.
            let rowWidth = newTabFrame.width > 0 ? newTabFrame.width : 240
            withAnimation(Motion.snappy) {
                lift = Lift(tabID: fav.id, isFavourite: true, origin: origin,
                            grab: CGSize(width: min(max(start.x - newTabFrame.minX, 20), rowWidth - 20), height: 17),
                            size: CGSize(width: rowWidth, height: 34))
                target = origin
            }
            return
        }
        location = point
        retarget = { [weak self] in
            guard let self, lift != nil, !settling else { return }
            let next = resolveFavouriteTarget(in: space)
            if next != target { withAnimation(Motion.snappy) { target = next } }
        }
        retarget?()
    }

    func ended(_ fav: Favorite, in space: Space, browser: Browser) {
        guard let lift, lift.isFavourite, !settling else { return }
        if target == nil { withAnimation(Motion.snappy) { target = lift.origin } }
        settling = true
        DispatchQueue.main.async { [self] in
            let firstPin = target?.isPinned == true && space.pinned.isEmpty
            let landing = firstPin ? pinZoneFrame : gapFrame
            withAnimation(Motion.snappy) {
                if target?.isFavourite == true {
                    location = CGPoint(x: landing.midX, y: landing.midY)
                } else {
                    location = CGPoint(x: landing.minX + lift.grab.width, y: landing.minY + lift.grab.height)
                }
            } completion: { [self] in
                commit(fav, in: space, browser: browser)
            }
        }
    }

    private func commit(_ fav: Favorite, in space: Space, browser: Browser) {
        defer {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { lift = nil; target = nil; settling = false }
        }
        guard let lift, let target, target != lift.origin else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            if case .favourite(let i) = target {
                browser.moveFavorite(fav, before: i < favouriteOrder.count ? browser.favorites.first { $0.id == favouriteOrder[i] } : nil)
                return
            }
            // Down into the list: its own tab if it has one here, otherwise a new one, and it's no
            // longer a favourite.
            let others = target.isPinned ? space.pinned : space.listedToday
            let before = target.index < others.count ? others[target.index] : nil
            let tab = space.today.first { $0.favoriteID == fav.id }
                ?? browser.newTab(url: fav.url, in: space, source: .bookmark, select: false)
            browser.removeFavorite(fav)
            browser.move(tab, before: before, pinned: target.isPinned)
        }
    }

    /// Like a tab's, but every tab in the list is another tab, and there's no moving to a space.
    private func resolveFavouriteTarget(in space: Space) -> Target? {
        if favouritesFrame != .zero, location.y < favouritesFrame.maxY + 6 {
            guard favouritesFrame.insetBy(dx: -12, dy: -12).contains(location) else { return nil }
            let before = favouriteOrder.filter { id in
                guard let r = tileFrames[id] else { return false }
                return r.maxY < location.y || (r.minY <= location.y && r.midX < location.x)
            }
            return .favourite(before.count)
        }
        guard !space.isPrivate else { return nil }
        let pinned = location.y < newTabFrame.midY
        let others = pinned ? space.pinned : space.listedToday
        let index = others.filter { (rowFrames[$0.id]?.midY ?? .infinity) < location.y }.count
        return pinned ? .pinned(index) : .today(index)
    }

    // MARK: Ending a tab's drag

    func ended(_ tab: BrowserTab, in space: Space, browser: Browser) {
        guard let lift, !lift.isFavourite, !settling else { return }
        // Nowhere useful: it goes home.
        if target == nil { withAnimation(Motion.snappy) { target = lift.origin } }
        settling = true
        // Let the gap find its final place before gliding into it. Pinning the first tab lands at
        // the top of the pin zone, where its row will be.
        if case .space(let id)? = target, let dot = spaceFrames[id] {
            withAnimation(Motion.snappy) {
                location = CGPoint(x: dot.midX, y: dot.midY)
                leaving = true
            } completion: { [self] in
                commit(tab, in: space, browser: browser)
                leaving = false
            }
            return
        }
        DispatchQueue.main.async { [self] in
            let firstPin = target?.isPinned == true && !space.pinned.contains { $0.id != lift.tabID }
            let landing = firstPin ? pinZoneFrame : gapFrame
            withAnimation(Motion.snappy) {
                if target?.isFavourite == true {
                    tileSize = landing.size
                    location = CGPoint(x: landing.midX, y: landing.midY)
                } else {
                    location = CGPoint(x: landing.minX + lift.grab.width, y: landing.minY + lift.grab.height)
                }
            } completion: { [self] in
                commit(tab, in: space, browser: browser)
            }
        }
    }

    private func commit(_ tab: BrowserTab, in space: Space, browser: Browser) {
        defer {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { lift = nil; target = nil; settling = false }
        }
        guard let lift, let target, target != lift.origin else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        if case .space(let id) = target {
            if let to = browser.spaces.first(where: { $0.id == id }) { withAnimation(Motion.spring) { browser.move(tab, to: to) } }
            return
        }
        if case .favourite(let i) = target {
            withTransaction(quiet) { makeFavourite(tab, at: i, browser: browser) }
            return
        }
        let others = (target.isPinned ? space.pinned : space.listedToday).filter { $0.id != tab.id }
        let before = target.index < others.count ? others[target.index] : nil
        withTransaction(quiet) { browser.move(tab, before: before, pinned: target.isPinned) }
    }

    /// The tab becomes a favourite at `index`, and the favourite's own tab, so it leaves the list
    /// and lives in its tile, as in Arc.
    private func makeFavourite(_ tab: BrowserTab, at index: Int, browser: Browser) {
        guard let url = tab.url else { return }
        let others = browser.sortedFavorites
        browser.addFavorite(url: url, title: tab.displayTitle)
        let key = URLNormalizer.key(for: url)
        guard let fav = browser.favorites.first(where: { URLNormalizer.key(for: $0.url) == key }) else { return }
        if index < others.count { browser.moveFavorite(fav, before: others[index]) }
        if tab.isPinned { browser.move(tab, before: nil, pinned: false) }
        tab.favoriteID = fav.id
        browser.scheduleSave()
    }

    // MARK: Targeting

    /// A tab can join the favourites if it has an address that isn't one already.
    func canFavourite(_ tab: BrowserTab, browser: Browser) -> Bool {
        guard !tab.isPrivate, let url = tab.url, !Welcome.isWelcome(url) else { return false }
        return !browser.library.isFavorite(url)
    }

    private func slot(of tab: BrowserTab, in space: Space) -> Target {
        if let i = space.pinned.firstIndex(where: { $0.id == tab.id }) { return .pinned(i) }
        return .today(space.listedToday.firstIndex { $0.id == tab.id } ?? 0)
    }

    /// Above the middle of New Tab is Pinned, below it is Today. Within a section, the slot is the
    /// number of other rows whose middle is above the pointer. Measured on the rows as laid out,
    /// gap included, which keeps it steady: a row that moves out of the way stays on its new side.
    private func resolveTarget(for tab: BrowserTab, in space: Space) -> Target? {
        if !tab.isPrivate, let (id, _) = spaceFrames.first(where: { $0.key != space.id && $0.value.insetBy(dx: -3, dy: -6).contains(location) }) {
            return .space(id)
        }
        // Up among the favourites: the slot is the number of tiles before the pointer, reading
        // left to right, top to bottom.
        if favouritesFrame != .zero, location.y < favouritesFrame.maxY + 6 {
            guard favouritesFrame.insetBy(dx: -12, dy: -12).contains(location), favouritesAllowed else { return nil }
            let before = favouriteOrder.filter { id in
                guard let r = tileFrames[id] else { return false }
                return r.maxY < location.y || (r.minY <= location.y && r.midX < location.x)
            }
            return .favourite(before.count)
        }
        let pinned = location.y < newTabFrame.midY && !space.isPrivate && !tab.isPrivate
        let others = (pinned ? space.pinned : space.listedToday).filter { $0.id != tab.id }
        let index = others.filter { (rowFrames[$0.id]?.midY ?? .infinity) < location.y }.count
        return pinned ? .pinned(index) : .today(index)
    }
}

/// The row under the pointer while a tab is dragged, raised a little above the sidebar. Over the
/// favourites it shrinks to a tile.
struct LiftedTabRow: View {
    @Environment(Browser.self) private var browser
    @Environment(SidebarDragging.self) private var dragging

    var body: some View {
        if let lift = dragging.lift, lift.isFavourite, let fav = browser.favorites.first(where: { $0.id == lift.tabID }) {
            liftedFavourite(fav, lift: lift)
        } else if let lift = dragging.lift, !lift.isFavourite,
           let tab = browser.currentSpace.allTabs.first(where: { $0.id == lift.tabID }) {
            // Over the favourites it's a tile; over a space's dot, a small chip that leaves the dot in view.
            let overSpace = if case .space? = dragging.target { true } else { false }
            let asTile = dragging.target?.isFavourite == true || overSpace
            let size = overSpace ? CGSize(width: 34, height: 30) : asTile ? dragging.tileSize : lift.size
            let origin = asTile
                ? CGPoint(x: dragging.location.x - size.width / 2,
                          y: dragging.location.y - size.height / 2 - (overSpace ? 30 : 0))
                : dragging.liftedOrigin
            // Raised on a card while it moves; settles back to how the row really looks as it lands.
            let selected = tab.id == browser.selectedTabID(in: browser.currentSpace)
            ZStack {
                TabRow(tab: tab, selected: selected || !dragging.settling, isLifted: true)
                    .frame(width: lift.size.width, height: lift.size.height)
                    .opacity(asTile ? 0 : 1)
                if let url = tab.url {
                    FaviconView(url: url, size: overSpace ? 18 : 26, chip: true, letter: tab.displayTitle)
                        .frame(width: size.width, height: size.height)
                        .background(SelectedFill(), in: .rect(cornerRadius: 12, style: .continuous))
                        .opacity(asTile ? 1 : 0)
                }
            }
            .frame(width: size.width, height: size.height)
            // Solid underneath, so the rows it passes over don't show through.
            .background(PanelFill(), in: .rect(cornerRadius: asTile ? 12 : 9, style: .continuous))
            .clipShape(.rect(cornerRadius: asTile ? 12 : 9, style: .continuous))
            .shadow(color: .black.opacity(dragging.settling ? 0.06 : 0.16), radius: dragging.settling ? 2 : 10,
                    y: dragging.settling ? 1 : 5)
            .scaleEffect(dragging.leaving ? 0.15 : dragging.settling ? 1 : 1.03, anchor: .init(
                x: lift.grab.width / max(lift.size.width, 1), y: lift.grab.height / max(lift.size.height, 1)))
            .opacity(dragging.leaving ? 0 : 1)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
            .transition(.identity)
        }
    }

    /// A favourite under the pointer: its tile among the favourites, a tab row over the list.
    private func liftedFavourite(_ fav: Favorite, lift: SidebarDragging.Lift) -> some View {
        let asRow = dragging.target?.isPinned == true || dragging.target?.isToday == true
        let size = asRow ? lift.size : dragging.tileSize
        let origin = asRow ? dragging.liftedOrigin
            : CGPoint(x: dragging.location.x - size.width / 2, y: dragging.location.y - size.height / 2)
        let name = fav.customName ?? fav.title
        return ZStack {
            HStack(spacing: 10) {
                FaviconView(url: fav.url, size: 16, letter: name)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(width: lift.size.width, height: lift.size.height)
            .opacity(asRow ? 1 : 0)
            FaviconView(url: fav.url, size: 26, chip: true, letter: name)
                .frame(width: size.width, height: size.height)
                .opacity(asRow ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .background(SelectedFill(), in: .rect(cornerRadius: asRow ? 9 : 12, style: .continuous))
        .background(PanelFill(), in: .rect(cornerRadius: asRow ? 9 : 12, style: .continuous))
        .clipShape(.rect(cornerRadius: asRow ? 9 : 12, style: .continuous))
        .shadow(color: .black.opacity(dragging.settling ? 0.06 : 0.16), radius: dragging.settling ? 2 : 10,
                y: dragging.settling ? 1 : 5)
        .scaleEffect(dragging.settling ? 1 : 1.04)
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(false)
        .transition(.identity)
    }
}
