import SwiftUI
import BrowserCore

/// A tab being dragged around the sidebar. The sidebar owns the whole drag rather than handing it
/// to the system: the row lifts and follows the pointer, the rows around it slide apart to show
/// where it will land, and on release it settles into that gap. Everything stays inside the sidebar.
@Observable @MainActor
final class SidebarDragging {
    /// Where a dragged tab would land: a slot among the other tabs of a section.
    enum Target: Equatable {
        case pinned(Int)
        case today(Int)

        var isPinned: Bool { if case .pinned = self { true } else { false } }
        var index: Int { switch self { case .pinned(let i), .today(let i): i } }
    }

    struct Lift {
        let tabID: UUID
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

    // Layout, reported by the views in the sidebar's coordinate space.
    var rowFrames: [UUID: CGRect] = [:]
    var newTabFrame: CGRect = .zero
    var gapFrame: CGRect = .zero
    /// The "Drop here to pin" zone, while it shows.
    var pinZoneFrame: CGRect = .zero
    /// The sidebar's top-left corner in the window, for tools that think in window points.
    var originInWindow: CGPoint = .zero

    #if SPIKE
    /// The most recently shown sidebar, for SpikeBrowsa's drag hook.
    static weak var latest: SidebarDragging?

    /// Drags the tab under `from` to `to` (window points) as a person would, over `duration`.
    func spikeDrag(from: CGPoint, to: CGPoint, duration: Double, browser: Browser) async -> Bool {
        let a = CGPoint(x: from.x - originInWindow.x, y: from.y - originInWindow.y)
        let b = CGPoint(x: to.x - originInWindow.x, y: to.y - originInWindow.y)
        let space = browser.currentSpace
        guard let tab = space.allTabs.first(where: { rowFrames[$0.id]?.contains(a) == true }) else { return false }
        let steps = max(2, Int(duration * 60))
        for i in 0...steps {
            // Ease in and out, like a hand.
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            changed(tab, from: a, to: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), in: space)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(150))
        ended(tab, in: space, browser: browser)
        return true
    }
    #endif

    func isLifted(_ id: UUID) -> Bool { lift?.tabID == id }

    /// The top-left corner the lifted row is drawn at.
    var liftedOrigin: CGPoint {
        guard let lift else { return .zero }
        return CGPoint(x: location.x - lift.grab.width, y: location.y - lift.grab.height)
    }

    // MARK: Gesture

    func changed(_ tab: BrowserTab, _ value: DragGesture.Value, in space: Space) {
        changed(tab, from: value.startLocation, to: value.location, in: space)
    }

    func changed(_ tab: BrowserTab, from start: CGPoint, to point: CGPoint, in space: Space) {
        guard !settling else { return }
        if lift == nil {
            guard let frame = rowFrames[tab.id] else { return }
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
        let next = resolveTarget(for: tab, in: space)
        if next != target { withAnimation(Motion.snappy) { target = next } }
    }

    func ended(_ tab: BrowserTab, in space: Space, browser: Browser) {
        guard let lift, !settling else { return }
        // Nowhere useful: it goes home.
        if target == nil { withAnimation(Motion.snappy) { target = lift.origin } }
        settling = true
        // Let the gap find its final place before gliding into it. Pinning the first tab lands at
        // the top of the pin zone, where its row will be.
        DispatchQueue.main.async { [self] in
            let firstPin = target?.isPinned == true && !space.pinned.contains { $0.id != lift.tabID }
            let landing = firstPin ? pinZoneFrame : gapFrame
            withAnimation(Motion.snappy) {
                location = CGPoint(x: landing.minX + lift.grab.width, y: landing.minY + lift.grab.height)
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
        let others = (target.isPinned ? space.pinned : space.listedToday).filter { $0.id != tab.id }
        let before = target.index < others.count ? others[target.index] : nil
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { browser.move(tab, before: before, pinned: target.isPinned) }
    }

    // MARK: Targeting

    private func slot(of tab: BrowserTab, in space: Space) -> Target {
        if let i = space.pinned.firstIndex(where: { $0.id == tab.id }) { return .pinned(i) }
        return .today(space.listedToday.firstIndex { $0.id == tab.id } ?? 0)
    }

    /// Above the middle of New Tab is Pinned, below it is Today. Within a section, the slot is the
    /// number of other rows whose middle is above the pointer. Measured on the rows as laid out,
    /// gap included, which keeps it steady: a row that moves out of the way stays on its new side.
    private func resolveTarget(for tab: BrowserTab, in space: Space) -> Target? {
        let pinned = location.y < newTabFrame.midY && !space.isPrivate && !tab.isPrivate
        let others = (pinned ? space.pinned : space.listedToday).filter { $0.id != tab.id }
        let index = others.filter { (rowFrames[$0.id]?.midY ?? .infinity) < location.y }.count
        return pinned ? .pinned(index) : .today(index)
    }
}

/// The row under the pointer while a tab is dragged, raised a little above the sidebar.
struct LiftedTabRow: View {
    @Environment(Browser.self) private var browser
    @Environment(SidebarDragging.self) private var dragging

    var body: some View {
        if let lift = dragging.lift,
           let tab = browser.currentSpace.allTabs.first(where: { $0.id == lift.tabID }) {
            // Raised on a card while it moves; settles back to how the row really looks as it lands.
            let selected = tab.id == browser.selectedTabID(in: browser.currentSpace)
            TabRow(tab: tab, selected: selected || !dragging.settling, isLifted: true)
                .frame(width: lift.size.width, height: lift.size.height)
                .shadow(color: .black.opacity(dragging.settling ? 0.06 : 0.16), radius: dragging.settling ? 2 : 10,
                        y: dragging.settling ? 1 : 5)
                .scaleEffect(dragging.settling ? 1 : 1.03)
                .offset(x: dragging.liftedOrigin.x, y: dragging.liftedOrigin.y)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }
}
