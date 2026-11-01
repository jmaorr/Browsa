import SwiftUI
import BrowserCore
import Suggest

/// The slim strip of tab icons that slides out from the leading edge.
///
/// - **Peek**: appears for ~1.4 s whenever you open or switch tabs (unless the docked sidebar
///   already shows them), so you always see where you are in the stack.
/// - **Scrub**: a swipe in from the leading edge brings it out under your finger. Slide up and
///   down to move the highlight (a haptic tick per tab), let go to switch. In the unfolded layout,
///   keep pulling outward and the gesture hands over to the full sidebar.
///
/// The highlight is computed from the finger's y with plain arithmetic on fixed row sizes, so
/// there's no per-frame geometry reading.
@MainActor @Observable
final class TabRailController {
    private(set) var isShown = false
    private(set) var isScrubbing = false
    private(set) var highlighted: UUID?
    /// Height of the area the rail is centred in. Set once per layout change.
    var containerHeight: CGFloat = 0
    /// True while the docked sidebar already lists the tabs; peeks are skipped then.
    var sidebarShowsTabs = false

    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var suppressNextPeek = false

    static let rowPitch: CGFloat = 46       // 38pt icon + 8pt spacing
    static let separator: CGFloat = 13
    static let padding: CGFloat = 8

    var pinned: [BrowserTab] { browser?.currentSpace.pinned ?? [] }
    var today: [BrowserTab] { browser?.currentSpace.today ?? [] }
    private var ordered: [BrowserTab] { pinned + today }

    var railHeight: CGFloat {
        let sep = (!pinned.isEmpty && !today.isEmpty) ? Self.separator : 0
        return Self.padding * 2 + CGFloat(ordered.count) * Self.rowPitch + sep
    }

    // MARK: Peek

    func currentTabChanged() {
        if suppressNextPeek { suppressNextPeek = false; return }
        guard !isScrubbing, !sidebarShowsTabs, ordered.count > 1 else { return }
        highlighted = browser?.currentTab?.id
        show()
        scheduleHide(after: .milliseconds(1400))
    }

    // MARK: Scrub

    func beginScrub() {
        hideTask?.cancel()
        isScrubbing = true
        highlighted = browser?.currentTab?.id
        show()
    }

    /// - Parameter y: finger position in the container's coordinate space.
    func scrub(toY y: CGFloat) {
        guard isScrubbing, !ordered.isEmpty else { return }
        let top = (containerHeight - railHeight) / 2 + Self.padding
        var local = y - top
        // Skip over the separator between pinned and today.
        let pinnedSpan = CGFloat(pinned.count) * Self.rowPitch
        if !pinned.isEmpty, !today.isEmpty, local > pinnedSpan {
            local = max(pinnedSpan, local - Self.separator)
        }
        let index = min(max(Int(local / Self.rowPitch), 0), ordered.count - 1)
        let id = ordered[index].id
        if id != highlighted { highlighted = id }
    }

    func commit() {
        guard isScrubbing else { return }
        isScrubbing = false
        if let id = highlighted, id != browser?.currentTab?.id,
           let tab = ordered.first(where: { $0.id == id }) {
            suppressNextPeek = true
            withAnimation(Motion.snappy) { browser?.select(tab) }
        }
        scheduleHide(after: .milliseconds(260))
    }

    /// The gesture turned into a sidebar reveal.
    func cancelScrub() {
        isScrubbing = false
        hide()
    }

    // MARK: Visibility

    private func show() {
        withAnimation(Motion.rail) { isShown = true }
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(Motion.rail) { isShown = false }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

/// The strip itself. Lives in RootView's overlay so both postures share it.
struct TabRailView: View {
    @Environment(TabRailController.self) private var rail

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rail.pinned) { icon($0) }
            if !rail.pinned.isEmpty && !rail.today.isEmpty {
                Capsule().fill(.separator).frame(width: 20, height: 1)
                    .frame(height: TabRailController.separator)
            }
            ForEach(rail.today) { icon($0) }
        }
        .padding(.vertical, TabRailController.padding)
        .frame(width: 54)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .offset(x: rail.isShown || Motion.reduced ? 8 : -84)   // Reduce Motion: fade in place
        .opacity(rail.isShown ? 1 : 0)
        .sensoryFeedback(.selection, trigger: rail.isScrubbing ? rail.highlighted : nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icon(_ tab: BrowserTab) -> some View {
        let on = tab.id == rail.highlighted
        return Group {
            if let url = tab.url { FaviconView(url: url, size: 30) }
            else { Image(systemName: "globe").frame(width: 30, height: 30) }
        }
        .frame(width: 38, height: 38)
        .background(on ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(on ? 0.15 : 0), radius: 4, y: 1)
        .scaleEffect(on ? 1.12 : 1)
        .frame(height: TabRailController.rowPitch)
        // Title bubble beside the highlighted icon.
        .overlay(alignment: .leading) {
            if on {
                Text(tab.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .fixedSize()
                    .offset(x: 52)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .animation(Motion.snappy, value: on)
    }
}

/// A thin invisible strip on the leading edge that starts a scrub.
/// `onHandOff` is called once if the finger keeps pulling outward past `handOffDistance`
/// (unfolded layout uses it to reveal the full sidebar); after that, `onSidebarDrag` and
/// `onSidebarEnd` receive the rest of the gesture.
struct TabRailEdge: View {
    @Environment(TabRailController.self) private var rail
    var handOffDistance: CGFloat? = nil
    var onHandOff: () -> Void = {}
    var onSidebarDrag: (_ dx: CGFloat) -> Void = { _ in }
    var onSidebarEnd: (_ predictedDx: CGFloat, _ velocity: CGFloat) -> Void = { _, _ in }

    @State private var handedOff = false
    @State private var began = false

    var body: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("browserRoot"))
                    .onChanged { v in
                        if !began { began = true; rail.beginScrub() }
                        let dx = v.translation.width
                        if let handOffDistance, !handedOff, dx > handOffDistance {
                            handedOff = true
                            rail.cancelScrub()
                            onHandOff()
                        }
                        if handedOff { onSidebarDrag(dx) } else { rail.scrub(toY: v.location.y) }
                    }
                    .onEnded { v in
                        if handedOff {
                            onSidebarEnd(v.predictedEndTranslation.width, v.velocity.width)
                        } else {
                            rail.commit()
                        }
                        handedOff = false
                        began = false
                    }
            )
            .accessibilityHidden(true)
    }
}
