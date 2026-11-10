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
    static func surfaceOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.10 : 0.06 }

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
    /// The sidebar docking or hiding. No overshoot: the page edge follows it and must not bounce.
    static let dockDuration = 0.3
    @MainActor static var dock: Animation { reduced ? calm : .smooth(duration: dockDuration) }
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
    /// A light tile behind the icon, so dark logos (GitHub, Apple) show on dark tints.
    var chip = false
    /// Shown until the icon loads. Defaults to the host's first letter.
    var letter: String?

    private var host: String { URLNormalizer.displayHost(url) }

    /// DuckDuckGo gives every Google app the plain "G". Google's own icon service tells Gmail, Meet,
    /// Drive, Calendar, Docs and Sheets apart by host and first path segment ("docs.google.com/
    /// spreadsheets"), so Google pages ask it, and send it no more than that.
    private var iconURL: URL? {
        let h = host.lowercased()
        if h == "google.com" || h.hasSuffix(".google.com") {
            let first = url.pathComponents.dropFirst().first.map { "/\($0)/" } ?? "/"
            var c = URLComponents(string: "https://t1.gstatic.com/faviconV2")
            c?.queryItems = [.init(name: "client", value: "SOCIAL"), .init(name: "type", value: "FAVICON"),
                             .init(name: "fallback_opts", value: "TYPE,SIZE,URL"),
                             .init(name: "url", value: "https://\(h)\(first)"), .init(name: "size", value: "64")]
            return c?.url
        }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }

    var body: some View {
        // Cached in memory, so a row that's rebuilt (dragged to another section, a space switch)
        // shows its icon straight away instead of flashing its letter while it loads again.
        FaviconImage(url: iconURL) { image in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .padding(chip ? size * 0.12 : 0)
                    .background(chip ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: size * 0.28, style: .continuous))
            } else {
                Text((letter ?? host).prefix(1).uppercased())
                    .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: size, height: size)
                    .background(.quaternary, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The raised look of the selected tab or favourite: a light pill in light mode, a lifted
/// translucent one in dark mode, never darker than the sidebar.
/// A slot pressed into the sidebar, where something dragged will land: lit from above, so the top
/// edge falls into shadow and the bottom edge catches the light. Deeper while it's the target.
struct SunkenSlot: View {
    var cornerRadius: CGFloat = 9
    var active = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(dark ? (active ? 0.26 : 0.2) : (active ? 0.065 : 0.05))
                .shadow(.inner(color: .black.opacity(dark ? 0.6 : (active ? 0.38 : 0.3)), radius: active ? 2.5 : 2, y: active ? 2 : 1.5))
                .shadow(.inner(color: .white.opacity(dark ? 0.08 : 0.8), radius: 0.5, y: -1)))
            .animation(Motion.snappy, value: active)
    }
}

struct SelectedFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.88)
    }
}

/// The opaque surface of floating panels (command bar, toasts, find), in the window's appearance.
struct PanelFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.985)
    }
}

/// A tab's icon: its favicon, or a globe before it has a page.
@MainActor private enum FaviconCache { static var images: [URL: NSImage] = [:] }

/// Loads a site icon once per launch and keeps it in memory.
private struct FaviconImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (NSImage?) -> Content
    @State private var image: NSImage?

    var body: some View {
        content(image ?? url.flatMap { FaviconCache.images[$0] })
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = FaviconCache.images[url] { image = hit; return }
                image = nil
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let loaded = NSImage(data: data) else { return }
                FaviconCache.images[url] = loaded
                image = loaded
            }
    }
}

struct TabIcon: View {
    let tab: BrowserTab
    var size: CGFloat = 16

    var body: some View {
        if Welcome.isWelcome(tab.url) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let url = tab.url {
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
