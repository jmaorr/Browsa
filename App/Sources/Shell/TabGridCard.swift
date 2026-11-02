import SwiftUI
import BrowserCore

let galleryCoordinates = "tabGallery"

/// Where each card's picture is. A plain reference, because it changes on every frame of a scroll
/// and only the hero's take-off reads it.
@MainActor final class CardFrames {
    var byTab: [UUID: CGRect] = [:]
}

/// One card: the page picture with a close button, and the title underneath.
struct TabGridCard: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    let aspect: CGFloat
    /// The hero is standing in for this card's picture.
    let hidden: Bool
    let frames: CardFrames
    var onOpen: () -> Void
    var onCloseTapped: () -> Void
    var onSwipedAway: () -> Void
    @State private var dragX: CGFloat = 0
    @State private var isPastCloseLine = false

    /// How far left a slow swipe has to go before letting go closes the tab.
    private let closeLine: CGFloat = 90

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onOpen) {
                // The clear shape alone sets the card's size, so the picture can't push it wider.
                Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(galleryCoordinates)) } action: {
                    frames.byTab[tab.id] = $0
                }
                .overlay {
                    if !hidden { TabThumbnail(tab: tab, image: browser.thumbnails[tab.id], cornerRadius: 14) }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      lineWidth: selected ? 2.5 : 0.5)
                        .opacity(hidden ? 0 : 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .buttonStyle(CardPressStyle())
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark", action: onCloseTapped)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .opacity(hidden ? 0 : 1)
            }
            HStack(spacing: 6) {
                if let url = tab.url { FaviconView(url: url, size: 14) }
                Text(tab.displayTitle).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .offset(x: dragX)
        .opacity(1 - min(0.6, abs(dragX) / 300))
        .gesture(HorizontalSwipeGesture(onChanged: dragged, onEnded: released))
        .sensoryFeedback(.selection, trigger: isPastCloseLine)
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityIdentifier("tabCard")
        .accessibilityValue(selected ? "Current tab" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Close Tab") { onSwipedAway() }
    }

    /// Follows the finger to the left, and resists to the right, where nothing happens.
    private func dragged(_ dx: CGFloat) {
        dragX = dx < 0 ? dx : dx * 0.15
        isPastCloseLine = dx < -closeLine
    }

    /// A slow swipe closes past the line. A flick closes sooner, but only if it travelled.
    private func released(dx: CGFloat, velocity: CGFloat) {
        isPastCloseLine = false
        if dx < -closeLine || (dx < -36 && velocity < -700) {
            withAnimation(Motion.snappy) { dragX = -600 } completion: { onSwipedAway() }
        } else {
            withAnimation(Motion.bouncy) { dragX = 0 }
        }
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A pan that only starts when the finger is moving clearly sideways. It's a UIKit recogniser so it
/// competes properly with the scroll view: whichever starts first wins and the other stands down,
/// which a SwiftUI simultaneous drag can't do.
private struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ dx: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: onChanged(dx)
        case .ended: onEnded(dx, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: onEnded(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 2
        }
    }
}

/// A tab's page picture, or its icon on a plain card when there isn't one yet.
struct TabThumbnail: View {
    let tab: BrowserTab
    let image: UIImage?
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                // In an overlay, because a scaled-to-fill image reports its overflowing size.
                Color.clear.overlay(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    if let url = tab.url { FaviconView(url: url, size: 40) }
                    else { Image(systemName: "plus.square.on.square").font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}
