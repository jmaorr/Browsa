import SwiftUI
import BrowserCore

/// Arc-style sidebar, written from scratch rather than NavigationSplitView so every frame of the
/// motion is ours:
///
/// - **Docked**: the sidebar pushes the page aside, and the page becomes an inset rounded card.
/// - **Hidden**: the page is full-bleed. Drag in from the sidebar edge to pull the sidebar out
///   under your finger. Let go past the halfway point (or flick) and it stays as a floating
///   **peek** panel over the page, otherwise it springs back.
/// - **Peek**: a floating, shadowed panel. Tap the page, pick a tab, or drag it back to dismiss.
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

    /// Live drag offset, in points toward "more open". Zero when not dragging.
    @GestureState private var drag: CGFloat = 0
    @State private var isDragging = false

    private let edgeHitWidth: CGFloat = 22
    private var sign: CGFloat { edge == .leading ? 1 : -1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: edge == .leading ? .leading : .trailing) {
                // Background tint shows through around the inset page card when docked.
                tint.opacity(0.14).ignoresSafeArea()

                pageCard
                    .padding(edge == .leading ? .leading : .trailing, dockedInset)
                    .padding(.vertical, cardInset)
                    .padding(edge == .leading ? .trailing : .leading, cardInset)
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

                // Invisible grab strip along the edge while hidden.
                if mode == .hidden {
                    Color.clear
                        .frame(width: edgeHitWidth)
                        .contentShape(.rect)
                        .gesture(revealGesture)
                        .ignoresSafeArea()
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
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background {
                if mode != .docked {
                    // Floating panel look when peeking.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 24, x: 8 * sign, y: 4)
                }
            }
            .padding(.vertical, mode == .docked ? 0 : 8)
            .padding(edge == .leading ? .leading : .trailing, mode == .docked ? 0 : 8)
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

    private func rubberBand(_ x: CGFloat) -> CGFloat {
        // Classic iOS rubber-band curve, tuned so a full-width overdrag moves ~8% of the width.
        (1 - 1 / (x * 0.55 / 0.08 + 1)) * 0.08
    }

    // MARK: Gestures

    private var revealGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($drag) { v, state, _ in state = max(0, v.translation.width * sign) }
            .onChanged { _ in isDragging = true }
            .onEnded { v in
                isDragging = false
                let projected = v.predictedEndTranslation.width * sign
                let velocity = v.velocity.width * sign
                set(projected > width * 0.5 ? .peek : .hidden, velocity: velocity)
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($drag) { v, state, _ in
                let dx = v.translation.width * sign
                // Closing direction is negative; opening further rubber-bands.
                state = dx
            }
            .onChanged { _ in isDragging = true }
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
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 320, damping: 30, initialVelocity: initial)) {
            mode = new
        }
    }
}
