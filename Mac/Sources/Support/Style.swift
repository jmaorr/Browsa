import SwiftUI
import AppKit
import BrowserCore
import Suggest

/// Space colours, the same six as the iPhone app.
enum SpacePalette {
    static let colors: [Color] = [.indigo, .orange, .teal, .pink, .green, .purple]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
    /// Private is a neutral grey.
    @MainActor static func color(for space: Space) -> Color { space.isPrivate ? .gray : color(space.colorIndex) }
    /// How strongly a space tints the sidebar background. The tint never reaches icons or the page.
    static let surfaceOpacity = 0.10

    /// Symbols offered for a space.
    static let symbols = ["house.fill", "briefcase.fill", "book.fill", "gamecontroller.fill", "cart.fill", "paintpalette.fill",
                          "graduationcap.fill", "heart.fill", "star.fill", "leaf.fill", "airplane", "music.note",
                          "film.fill", "hammer.fill", "chart.bar.fill", "circle.fill"]
}

/// One motion vocabulary, shared with the iPhone app. Reduce Motion turns springs into short eases.
enum Motion {
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let calm = Animation.easeInOut(duration: 0.18)

    @MainActor static var spring: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 320, damping: 30) }
    @MainActor static var snappy: Animation { reduced ? calm : .snappy(duration: 0.26) }
    @MainActor static var bouncy: Animation { reduced ? calm : .bouncy(duration: 0.35, extraBounce: 0.08) }
    /// The undocked sidebar sliding over the page.
    @MainActor static var peek: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 380, damping: 34) }
}

// MARK: - Space switch cascade

/// A tab row arriving because the space changed slides in from the new space's side, each a beat
/// after the last. Rows that appear for any other reason just appear.
private struct SpaceCascade: ViewModifier {
    let index: Int
    let distance: CGFloat
    let forward: Bool
    @State private var arrived: Bool

    init(index: Int, distance: CGFloat, spaceSwitch: SpaceSwitch?) {
        self.index = index
        self.distance = distance
        forward = spaceSwitch?.forward ?? true
        let justSwitched = spaceSwitch.map { Date().timeIntervalSince($0.at) < 0.3 } ?? false
        _arrived = State(initialValue: !justSwitched)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: arrived || Motion.reduced ? 0 : (forward ? distance : -distance))
            .opacity(arrived ? 1 : 0)
            .onAppear {
                guard !arrived else { return }
                withAnimation(Motion.spring.delay(Double(min(index, 8)) * 0.035)) { arrived = true }
            }
    }
}

extension View {
    func spaceCascade(index: Int, distance: CGFloat = 120, spaceSwitch: SpaceSwitch?) -> some View {
        modifier(SpaceCascade(index: index, distance: distance, spaceSwitch: spaceSwitch))
    }
}

extension AnyTransition {
    /// The outgoing list leaves toward the side away from the new space.
    @MainActor static func spaceListChange(forward: Bool) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(insertion: .identity,
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}

// MARK: - Favicons

/// Site icon from DuckDuckGo's icon service (sends only the host), with a letter tile meanwhile.
struct FaviconView: View {
    let url: URL
    var size: CGFloat = 16

    private var host: String { URLNormalizer.displayHost(url) }

    var body: some View {
        AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFit()
            } else {
                Text(host.prefix(1).uppercased())
                    .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A tab's icon: its favicon, or a globe before it has a page.
struct TabIcon: View {
    let tab: BrowserTab
    var size: CGFloat = 16

    var body: some View {
        if let url = tab.url {
            FaviconView(url: url, size: size)
        } else {
            Image(systemName: tab.isPrivate ? "eye.slash" : "globe")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - AppKit bridges

/// The translucent window material behind the sidebar and around the page.
struct WindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Reaches the hosting NSWindow, to set it up and hide the traffic lights with the sidebar.
struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.configure = configure
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {
        v.configure = configure
        if let w = v.window { configure(w) }
    }

    final class Probe: NSView {
        var configure: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure?(window) }
        }
    }
}
