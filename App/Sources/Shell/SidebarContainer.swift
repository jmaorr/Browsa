import SwiftUI
import BrowserCore

/// Arc-style sidebar, written from scratch rather than NavigationSplitView so every frame of the
/// motion is ours:
///
/// - **Docked**: the sidebar pushes the page aside, and the page becomes an inset rounded card.
/// - **Hidden**: the page is full-bleed. A swipe in from the leading edge brings out the tab strip.
///
/// Laying out a web view is slow, so the page never resizes during the animation. It changes size
/// once, while it's off to the side of its final position, and the motion itself only slides it.
struct SidebarContainer<Sidebar: View, Content: View>: View {
    var isDocked: Bool
    /// Which screen edge the sidebar lives on.
    var edge: HorizontalEdge
    var width: CGFloat = 288
    var tint: Color
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content

    /// The page's actual size follows this, not `isDocked`, so it changes only between animations.
    @State private var laidOutDocked: Bool
    @State private var slide: CGFloat = 0
    /// Top and bottom margin and corner radius drawn by clipping while the page slides.
    @State private var clipInset: CGFloat = 0
    @State private var radius: CGFloat
    /// Bumped by every move, so a move that was overtaken can't finish on top of the newer one.
    @State private var moveID = 0

    private let cardInset: CGFloat = 8
    private let cardRadius: CGFloat = 14
    private var sign: CGFloat { edge == .leading ? 1 : -1 }

    init(isDocked: Bool, edge: HorizontalEdge, width: CGFloat = 288, tint: Color,
         @ViewBuilder sidebar: @escaping () -> Sidebar, @ViewBuilder content: @escaping () -> Content) {
        self.isDocked = isDocked
        self.edge = edge
        self.width = width
        self.tint = tint
        self.sidebar = sidebar
        self.content = content
        _laidOutDocked = State(initialValue: isDocked)
        _radius = State(initialValue: isDocked ? 14 : 0)
    }

    var body: some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            // The space's colour, behind the sidebar and around the inset page card.
            tint.opacity(isDocked ? 0.14 : 0).ignoresSafeArea()

            pageCard

            sidebar()
                .padding(.vertical, cardInset)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
                .offset(x: isDocked ? 0 : -(width + 16) * sign)
                .allowsHitTesting(isDocked)
        }
        // Edge swipe while hidden: scrub the tab strip.
        .overlay(alignment: .leading) {
            if !isDocked { TabRailEdge() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isDocked)
        .onChange(of: isDocked) { _, docked in docked ? dock() : undock() }
        // Coming back from the other posture: any move in progress never got to finish.
        .onAppear { settle() }
    }

    private var pageCard: some View {
        content()
            .clipShape(PageClip(inset: clipInset, radius: radius))
            .shadow(color: .black.opacity(radius > 0 ? 0.08 : 0), radius: 10, y: 2)
            .padding(edge == .leading ? .leading : .trailing, laidOutDocked ? width : 0)
            .padding(.vertical, laidOutDocked ? cardInset : 0)
            .padding(edge == .leading ? .trailing : .leading, laidOutDocked ? 2 : 0)
            .offset(x: slide * sign)
            // Keeps the sliding page out of the vertical bar's strip.
            .clipped()
            // The card measures its margin from the screen, not from the safe area.
            .ignoresSafeArea(.container, edges: .vertical)
    }

    /// Slide the full-size page aside, then resize it to fit beside the sidebar.
    private func dock() {
        moveID += 1
        let move = moveID
        withAnimation(Motion.spring) {
            slide = width
            clipInset = cardInset
            radius = cardRadius
        } completion: {
            guard move == moveID else { return }
            settle()
        }
    }

    /// Resize the page to full size while it's still beside the sidebar, then slide it into place.
    private func undock() {
        moveID += 1
        let move = moveID
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if laidOutDocked {
                laidOutDocked = false
                slide = width
                clipInset = cardInset
            }
        }
        Task { @MainActor in
            await Task.yield()
            guard move == moveID else { return }
            withAnimation(Motion.spring) {
                slide = 0
                clipInset = 0
                radius = 0
            }
        }
    }

    /// Puts everything exactly where `isDocked` says, with no animation.
    private func settle() {
        moveID += 1
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            laidOutDocked = isDocked
            slide = 0
            clipInset = 0
            radius = isDocked ? cardRadius : 0
        }
    }
}

/// The page card's outline while it slides: a rounded rectangle pulled in from the top and bottom.
private struct PageClip: Shape {
    var inset: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, radius) }
        set { inset = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect.insetBy(dx: 0, dy: inset), cornerRadius: radius, style: .continuous)
    }
}
