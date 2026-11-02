import SwiftUI
import BrowserCore

/// Arc-style sidebar, written from scratch rather than NavigationSplitView so every frame of the
/// motion is ours:
///
/// - **Docked**: the sidebar pushes the page aside, and the page becomes an inset rounded card.
/// - **Hidden**: the page is full-bleed. A short swipe in from the edge brings out the tab strip;
///   keep pulling and the strip itself grows into the sidebar (titles slide in beside the icons,
///   the address field and spaces fade in). Let go past halfway (or flick) and it settles as the
///   **peek** sidebar, otherwise it shrinks back to icons and tucks away.
/// - **Peek**: a panel attached to the screen edge, over the page. Tap the page, pick a tab, or
///   drag it back to dismiss.
///   Press the toggle while peeking to dock it.
///
/// All transitions are velocity-matched springs, so a fast flick lands fast and you can grab
/// the sidebar mid-animation.
struct SidebarContainer<Sidebar: View, Content: View>: View {
    enum Mode: Equatable { case docked, hidden, peek }

    @Binding var mode: Mode
    /// Which screen edge the sidebar lives on.
    var edge: HorizontalEdge
    var width: CGFloat = 288
    var tint: Color
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content

    /// Live drag offset, in points toward "more open". Zero when not dragging. Plain @State (not
    /// @GestureState) so the release animates from exactly where the finger left it.
    @State private var drag: CGFloat = 0
    @Environment(TabRailController.self) private var rail
    /// Where the edge drag stops scrubbing tabs and the strip starts growing into the sidebar.
    private let handOffDistance: CGFloat = 110
    @State private var isDragging = false
    private var sign: CGFloat { edge == .leading ? 1 : -1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: edge == .leading ? .leading : .trailing) {
                // Background tint shows through around the inset page card when docked.
                tint.opacity(0.14).ignoresSafeArea()

                pageCard
                    .padding(edge == .leading ? .leading : .trailing, dockedInset)
                    .padding(.vertical, cardInset)
                    .padding(edge == .leading ? .trailing : .leading, cardInset > 0 ? 2 : 0)
                    // The card measures its margin from the screen, not from the safe area.
                    .ignoresSafeArea(.container, edges: .vertical)
                    .overlay {
                        // Dimming + tap-to-dismiss while peeking.
                        if mode == .peek || (mode == .hidden && revealFraction > 0) {
                            Color.black.opacity(0.12 * revealFraction)
                                .ignoresSafeArea()
                                .onTapGesture { set(.hidden) }
                                .transition(.opacity)
                        }
                    }

                sidebarLayer

                // Edge swipe while hidden: scrub the tab strip, or keep pulling for the sidebar.
                if mode == .hidden {
                    if edge == .leading {
                        // The tab strip grows into the sidebar under your finger, then the real
                        // sidebar takes over in exactly the same place.
                        TabRailEdge(
                            handOffDistance: handOffDistance,
                            onHandOff: {
                                rail.expandedWidth = width
                                rail.beginExpand()
                            },
                            onSidebarDrag: { dx in rail.expansion = growth(dx) },
                            onSidebarEnd: { predicted, velocity in
                                let span = width - TabRailView.width
                                if growth(predicted) > 0.5 {
                                    withAnimation(Motion.spring(initialVelocity: Double(abs(velocity) / span))) {
                                        rail.expansion = 1
                                    } completion: {
                                        var t = Transaction(); t.disablesAnimations = true
                                        withTransaction(t) { mode = .peek; drag = 0 }
                                        rail.handOffToSidebar()
                                    }
                                } else {
                                    rail.collapseExpansion(velocity: velocity / span)
                                }
                            })
                    } else {
                        // Sidebar on the trailing edge (vertical bar on the left): drag it out directly.
                        TabRailEdge(
                            handOffDistance: 130,
                            onHandOff: { rail.cancelScrub(); isDragging = true },
                            onSidebarDrag: { dx in drag = max(0, dx * sign - 40) },
                            onSidebarEnd: { predicted, velocity in
                                isDragging = false
                                set(predicted * sign - 40 > width * 0.5 ? .peek : .hidden, velocity: velocity * sign)
                            })
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: mode)
        }
    }

    // MARK: Layers

    private var pageCard: some View {
        content()
            .clipShape(.rect(cornerRadius: mode == .docked ? 14 : 0, style: .continuous))
            .shadow(color: .black.opacity(mode == .docked ? 0.08 : 0), radius: 10, y: 2)
    }

    private var sidebarLayer: some View {
        sidebar()
            .padding(.vertical, 8)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .vertical)
            .background {
                if mode != .docked {
                    // Peeking, it's attached to the screen edge like the tab strip it grows out
                    // of: square against the edge, rounded on the open side.
                    UnevenRoundedRectangle(
                        topLeadingRadius: edge == .leading ? 0 : 20, bottomLeadingRadius: edge == .leading ? 0 : 20,
                        bottomTrailingRadius: edge == .leading ? 20 : 0, topTrailingRadius: edge == .leading ? 20 : 0,
                        style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.22), radius: 24, x: 8 * sign, y: 4)
                        .ignoresSafeArea(edges: .vertical)
                }
            }
            .offset(x: sidebarOffset * sign)
            .opacity(mode == .hidden && drag == 0 ? 0 : 1)
            .gesture(dismissGesture)
            .allowsHitTesting(mode != .hidden || isDragging)
    }

    // MARK: Geometry

    /// How open the sidebar is, 0...1 (can overshoot slightly while rubber-banding).
    private var revealFraction: CGFloat {
        let base: CGFloat = mode == .hidden ? 0 : 1
        return max(0, min(1.06, base + drag / width))
    }

    /// Horizontal offset of the sidebar from its open position (negative = off-screen).
    private var sidebarOffset: CGFloat {
        let f = revealFraction
        if f > 1 { return rubberBand(f - 1) * width }   // past fully open: resist
        return -(1 - f) * (width + 16)
    }

    /// Leading padding the page card gets so the docked sidebar doesn't cover it.
    private var dockedInset: CGFloat {
        guard mode == .docked else { return 0 }
        return max(0, width * revealFraction) + 0
    }

    private var cardInset: CGFloat { mode == .docked ? 8 : 0 }

    /// Edge drag distance to strip growth: 0 at the hand-off point, 1 at full sidebar width,
    /// resisting beyond that.
    private func growth(_ dx: CGFloat) -> CGFloat {
        let f = max(0, (dx - handOffDistance) / (width - TabRailView.width))
        return f <= 1 ? f : 1 + rubberBand(f - 1)
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat {
        // Classic iOS rubber-band curve, tuned so a full-width overdrag moves ~8% of the width.
        (1 - 1 / (x * 0.55 / 0.08 + 1)) * 0.08
    }

    // MARK: Gestures

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                isDragging = true
                // Closing direction is negative; opening further rubber-bands.
                drag = v.translation.width * sign
            }
            .onEnded { v in
                isDragging = false
                let projected = v.predictedEndTranslation.width * sign
                if projected < -width * 0.4 {
                    set(.hidden, velocity: v.velocity.width * sign)
                } else {
                    set(mode, velocity: v.velocity.width * sign)
                }
            }
    }

    private func set(_ new: Mode, velocity: CGFloat = 0) {
        // Convert the finger's px/s into the spring's unit-per-second for a seamless hand-off.
        let initial = Double(abs(velocity) / max(width, 1))
        withAnimation(Motion.spring(initialVelocity: initial)) {
            mode = new
            drag = 0
        }
    }
}
