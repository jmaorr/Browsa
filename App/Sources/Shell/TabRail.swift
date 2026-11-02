import SwiftUI
import BrowserCore
import Suggest

/// The slim strip of tab icons that grows out of the leading edge of the screen, like a notch:
/// it's attached to the edge, and its top and bottom flare into the edge with concave curves.
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

    /// Unfolded only: how far the strip has grown into the full sidebar, 0 (icons) … 1 (sidebar),
    /// overshooting a little while rubber-banding. Driven by the edge drag.
    var expansion: CGFloat = 0
    /// Width of the sidebar the strip grows into.
    var expandedWidth: CGFloat = 288
    /// The real sidebar has taken over; the strip fades out in place.
    private(set) var handedOff = false

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

    // MARK: Growing into the sidebar (unfolded)

    /// Keep pulling past the scrub: stop scrubbing and start growing. The highlight goes back to
    /// the current tab, which is what the sidebar will show selected.
    func beginExpand() {
        hideTask?.cancel()
        isScrubbing = false
        highlighted = browser?.currentTab?.id
        show()
    }

    /// The strip reached full size and the real sidebar is now in exactly its place: fade the
    /// strip out, then reset it without animation.
    func handOffToSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { handedOff = true } completion: { [weak self] in
            guard let self else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                self.expansion = 0
                self.isShown = false
                self.handedOff = false
            }
        }
    }

    /// Let go before halfway: shrink back to icons, then tuck away.
    func collapseExpansion(velocity: CGFloat = 0) {
        withAnimation(Motion.spring(initialVelocity: Double(abs(velocity)))) { expansion = 0 } completion: { [weak self] in
            self?.scheduleHide(after: .milliseconds(120))
        }
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
///
/// Rather than a floating panel sliding in, the shape's width grows from zero at the screen edge
/// (one spring on `reveal`), so the flares stay pinned to the edge and swell with it while the
/// icons drift out from under the edge.
struct TabRailView: View {
    @Environment(TabRailController.self) private var rail
    nonisolated static let width: CGFloat = 54

    /// 0 = icon strip, 1 = full sidebar (unfolded drag only).
    private var e: CGFloat { max(0, rail.expansion) }
    private var width: CGFloat { Self.width + e * (rail.expandedWidth - Self.width) }
    private var height: CGFloat? {
        guard e > 0 else { return nil }
        let full = max(rail.railHeight, rail.containerHeight)
        return rail.railHeight + min(e, 1) * (full - rail.railHeight)
    }

    var body: some View {
        let reveal: CGFloat = rail.isShown ? 1 : 0
        VStack(spacing: 0) {
            ForEach(rail.pinned) { icon($0) }
            if !rail.pinned.isEmpty && !rail.today.isEmpty {
                Capsule().fill(.separator).frame(width: 20, height: 1)
                    .frame(height: TabRailController.separator)
                    .frame(width: Self.width)
            }
            ForEach(rail.today) { icon($0) }
        }
        .padding(.vertical, TabRailController.padding)
        .opacity(Motion.reduced ? reveal : max(0, reveal * 1.6 - 0.3))
        .scaleEffect(Motion.reduced ? 1 : 0.85 + 0.15 * reveal, anchor: .leading)
        .offset(x: Motion.reduced ? 0 : (reveal - 1) * 26)
        .frame(width: width, height: height, alignment: .leading)
        // Growing into the sidebar: its address field and footer fade in around the tabs.
        .overlay(alignment: .top) { if e > 0 { sidebarHeader.opacity(min(1, e * e)) } }
        .overlay(alignment: .bottom) { if e > 0 { sidebarFooter.opacity(min(1, e * e)) } }
        .background(alignment: .leading) {
            EdgeNotchShape(reveal: Motion.reduced ? 1 : reveal, fullWidth: width, flare: 20 * (1 - min(e, 1)))
                .fill(.regularMaterial)
                .shadow(color: .black.opacity((0.16 + 0.06 * min(e, 1)) * reveal), radius: 10 + 14 * min(e, 1), x: 2)
                .opacity(Motion.reduced ? reveal : 1)   // Reduce Motion: fade in place
        }
        .opacity(rail.handedOff ? 0 : 1)
        // Flush with the physical edge, even where there's a safe-area inset.
        .ignoresSafeArea(edges: .horizontal)
        .sensoryFeedback(.selection, trigger: rail.isScrubbing ? rail.highlighted : nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(rail.browser?.currentTab?.url.map(URLNormalizer.displayHost) ?? "Search or enter address")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 12)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            ForEach(rail.browser?.spaces ?? []) { s in
                Image(systemName: s.symbol).font(.footnote)
                    .foregroundStyle(s.id == rail.browser?.selectedSpaceID ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    private func icon(_ tab: BrowserTab) -> some View {
        let on = tab.id == rail.highlighted
        return HStack(spacing: 10) {
            Group {
                if let url = tab.url { FaviconView(url: url, size: 30) }
                else { Image(systemName: "globe").frame(width: 30, height: 30) }
            }
            .frame(width: 38, height: 38)
            // Titles slide in beside the icons, which stay put, as the strip becomes the sidebar.
            if e > 0 {
                Text(tab.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .opacity(min(1, e * 1.4 - 0.25))
                Spacer(minLength: 0)
            }
        }
        .frame(width: e > 0 ? width - 16 : 38, height: 38, alignment: .leading)
        .background(on ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 11, style: .continuous))
        .scaleEffect(on && e == 0 ? 1.12 : 1, anchor: .leading)
        .padding(.leading, 8)
        .frame(height: TabRailController.rowPitch)
        // Title bubble beside the highlighted icon (not while growing: the row shows its title).
        .overlay(alignment: .leading) {
            if on && e == 0 {
                Text(tab.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .fixedSize()
                    .offset(x: 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .animation(Motion.snappy, value: on)
    }
}

/// The strip's outline: flat against the screen edge, rounded on the outside, and flaring into
/// the edge above and below with concave curves, so it reads as part of the display rather than
/// a card on top of it. `reveal` (0…1) grows it out of the edge; both the width and the flares
/// scale with it, and it animates as a plain number.
struct EdgeNotchShape: Shape {
    var reveal: CGFloat
    var fullWidth: CGFloat = 54
    var cornerRadius: CGFloat = 20
    var flare: CGFloat = 20

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(reveal, AnimatablePair(fullWidth, flare)) }
        set { reveal = newValue.first; fullWidth = newValue.second.first; flare = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, reveal)
        let w = fullWidth * p
        guard w > 0.5 else { return Path() }
        let f = flare * min(p, 1)
        let r = min(cornerRadius, w, rect.height / 2)
        let x0 = rect.minX, top = rect.minY, bottom = rect.maxY
        // A cubic with handles at ~55% gives a smooth, continuous-looking flare.
        let k: CGFloat = 0.55
        var path = Path()
        path.move(to: CGPoint(x: x0, y: top - f))
        path.addCurve(to: CGPoint(x: x0 + f, y: top),
                      control1: CGPoint(x: x0, y: top - f + f * k),
                      control2: CGPoint(x: x0 + f - f * k, y: top))
        path.addLine(to: CGPoint(x: x0 + w - r, y: top))
        path.addQuadCurve(to: CGPoint(x: x0 + w, y: top + r), control: CGPoint(x: x0 + w, y: top))
        path.addLine(to: CGPoint(x: x0 + w, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: x0 + w - r, y: bottom), control: CGPoint(x: x0 + w, y: bottom))
        path.addLine(to: CGPoint(x: x0 + f, y: bottom))
        path.addCurve(to: CGPoint(x: x0, y: bottom + f),
                      control1: CGPoint(x: x0 + f - f * k, y: bottom),
                      control2: CGPoint(x: x0, y: bottom + f - f * k))
        path.closeSubpath()
        return path
    }
}

/// A thin invisible strip on the leading edge that starts a scrub.
/// `onHandOff` is called once if the finger keeps pulling outward past `handOffDistance`
/// (unfolded layout uses it to grow the strip into the sidebar); after that, `onSidebarDrag` and
/// `onSidebarEnd` receive the rest of the gesture. The owner decides what happens to the strip.
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
