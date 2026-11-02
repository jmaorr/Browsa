import SwiftUI
import BrowserCore
import Suggest

/// The slim strip of tab icons that grows out of the leading edge of the screen, like a notch:
/// it's attached to the edge, and its top and bottom flare into the edge with concave curves.
///
/// - **Peek**: appears for ~1.4 s whenever you open or switch tabs (unless the docked sidebar
///   already shows them), so you always see where you are in the stack.
/// - **Scrub**: a swipe in from the leading edge brings it out under your finger. Slide up and
///   down to move the highlight (a haptic tick per tab), let go to switch.
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
        // A space change cascades its tabs in wherever they're listed, so it doesn't peek as well.
        let changedSpace = browser?.lastSpaceSwitch.map { Date().timeIntervalSince($0.at) < 0.3 } ?? false
        guard !isScrubbing, !sidebarShowsTabs, !changedSpace, ordered.count > 1 else { return }
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

    /// Tucks the strip away at once, wherever it had got to.
    func reset() {
        hideTask?.cancel()
        isScrubbing = false
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { isShown = false }
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
        .frame(width: Self.width, alignment: .leading)
        .background(alignment: .leading) {
            EdgeNotchShape(reveal: Motion.reduced ? 1 : reveal, fullWidth: Self.width)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16 * reveal), radius: 10, x: 2)
                .opacity(Motion.reduced ? reveal : 1)   // Reduce Motion: fade in place
        }
        // Flush with the physical edge, even where there's a safe-area inset.
        .ignoresSafeArea(edges: .horizontal)
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
        .background(on ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 11, style: .continuous))
        .scaleEffect(on ? 1.12 : 1, anchor: .leading)
        .padding(.leading, 8)
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
struct TabRailEdge: View {
    @Environment(TabRailController.self) private var rail
    @GestureState private var isDragging = false
    @State private var began = false

    var body: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("browserRoot"))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { v in
                        if !began { began = true; rail.beginScrub() }
                        rail.scrub(toY: v.location.y)
                    }
            )
            // Also fires when the system cancels the gesture, which never reaches onEnded.
            .onChange(of: isDragging) { _, dragging in
                if !dragging { finish() }
            }
            .onDisappear { finish() }
            .accessibilityHidden(true)
    }

    private func finish() {
        guard began else { return }
        began = false
        rail.commit()
    }
}
