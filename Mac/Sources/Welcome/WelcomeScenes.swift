import SwiftUI
import AppKit

// The welcome gallery's cards: each stop's surface (paper, mesh gradient, grain, brushed
// aluminium) and its hero, a looping miniature of the real Browsa UI it teaches.

// MARK: - Surfaces

enum CardSurface {
    /// Clean page-coloured card with a hairline: the quiet ones.
    case paper
    /// A soft mesh of colours, deep enough for white text.
    case mesh([Color])
    /// A soft mesh of light colours, taking dark text.
    case meshLight([Color])
    /// A dark gradient with film grain.
    case grain(Color, Color)
    /// Brushed aluminium, like the keyboard deck.
    case aluminium
    /// Browsa's own look: the icon's lilac-blue and ember, softly meshed.
    case browsa

    /// Text on this surface: dark surfaces always take white.
    func isDark(_ scheme: ColorScheme) -> Bool {
        switch self {
        case .paper, .aluminium: scheme == .dark
        case .meshLight, .browsa: scheme == .dark
        case .mesh, .grain: true
        }
    }
}

struct SurfaceBackground: View {
    let surface: CardSurface
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch surface {
        case .paper:
            scheme == .dark ? Color(white: 0.135) : Color.white
        case .meshLight(let c) where scheme == .dark:
            // The same hues, dimmed for dark mode: deep enough for white text, still clearly coloured.
            mesh(c.map { Self.dim($0) })
                .overlay(Grain(opacity: 0.06))
        case .mesh(let c) where scheme == .dark:
            // The deep meshes only step down a little in dark mode.
            mesh(c.map { Self.dim($0, by: 0.72, saturate: 1.05) })
        case .mesh(let c), .meshLight(let c):
            mesh(c)
        case .grain(let a, let b):
            LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Grain(opacity: 0.09))
        case .browsa:
            let dark = scheme == .dark
            // The icon: lilac and periwinkle from the tile, ember and gold from the swirl.
            mesh(dark ? [Color(red: 0.2, green: 0.17, blue: 0.4), Color(red: 0.36, green: 0.14, blue: 0.3),
                         Color(red: 0.14, green: 0.2, blue: 0.42), Color(red: 0.48, green: 0.18, blue: 0.1)]
                      : [Color(red: 0.84, green: 0.8, blue: 1.0), Color(red: 0.98, green: 0.82, blue: 0.9),
                         Color(red: 0.76, green: 0.84, blue: 1.0), Color(red: 1.0, green: 0.8, blue: 0.62)])
                .overlay(Grain(opacity: dark ? 0.06 : 0.04))
        case .aluminium:
            // Softly brushed: a gentle sheen and faint grain, not hard stripes.
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.24), Color(white: 0.19)] : [Color(white: 0.965), Color(white: 0.9)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.04 : 0.35), .clear, .white.opacity(scheme == .dark ? 0.02 : 0.15)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Brushed(dark: scheme == .dark).opacity(0.35))
        }
    }

    private func mesh(_ c: [Color]) -> some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.55, 0], [1, 0],
            [0, 0.5], [0.42, 0.58], [1, 0.42],
            [0, 1], [0.6, 1], [1, 1],
        ], colors: (0..<9).map { c[$0 % c.count] })
    }

    /// A light mesh colour for dark mode: same hue, a little more saturated, much lower brightness.
    static func dim(_ color: Color, by brightness: CGFloat = 0.42, saturate: CGFloat = 1.5) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(1, s * saturate + (saturate > 1.2 ? 0.15 : 0)), brightness: b * brightness)
    }
}

/// Film grain: one small tile, drawn once from a fixed seed and repeated, so it costs nothing per frame.
struct Grain: View {
    var opacity: Double
    var body: some View {
        Image(decorative: Texture.grain, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(opacity / 0.09)
            .allowsHitTesting(false)
    }
}

/// Fine horizontal brushing, from a cached tile.
struct Brushed: View {
    let dark: Bool
    var body: some View {
        Image(decorative: Texture.brushed, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(dark ? 0.6 : 1)
            .allowsHitTesting(false)
    }
}

/// Texture tiles, made once with Core Graphics.
enum Texture {
    static let grain: CGImage = make(size: 256) { ctx, rng in
        for _ in 0..<(256 * 256 / 7) {
            let x = rng.next() * 256, y = rng.next() * 256
            let light = rng.next() > 0.5
            ctx.setFillColor(gray: light ? 1 : 0, alpha: 0.09 * (0.4 + rng.next()))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }

    static let brushed: CGImage = make(size: 256) { ctx, rng in
        var y = 0.0
        while y < 256 {
            ctx.setFillColor(gray: rng.next() > 0.5 ? 1 : 0, alpha: 0.02 + rng.next() * 0.05)
            ctx.fill(CGRect(x: 0, y: y, width: 256, height: 1))
            y += 1.4 + rng.next() * 2.8
        }
    }

    private static func make(size: Int, draw: (CGContext, inout SeededRandom) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SeededRandom(seed: UInt64(size) &+ 7)
        draw(ctx, &rng)
        return ctx.makeImage()!
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

extension WelcomeStop {
    var surface: CardSurface {
        switch self {
        case .spaces: .browsa
        case .newTab, .commands: .aluminium
        case .importing: .meshLight([Color(red: 0.74, green: 0.84, blue: 1.0), Color(red: 0.86, green: 0.82, blue: 1.0),
                                     Color(red: 0.7, green: 0.9, blue: 0.96), Color(red: 0.93, green: 0.9, blue: 1.0)])
        case .tour: .grain(Color(red: 0.36, green: 0.06, blue: 0.16), Color(red: 0.12, green: 0.04, blue: 0.1))
        case .library: .meshLight([Color(red: 0.7, green: 0.93, blue: 0.82), Color(red: 0.86, green: 0.97, blue: 0.78),
                                   Color(red: 0.62, green: 0.88, blue: 0.86), Color(red: 0.9, green: 0.98, blue: 0.88)])
        case .agents: .grain(Color(red: 0.08, green: 0.1, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.06))
        case .makeDefault: .mesh([Color(red: 0.98, green: 0.62, blue: 0.2), Color(red: 0.86, green: 0.25, blue: 0.08),
                                  Color(red: 0.99, green: 0.83, blue: 0.45), Color(red: 0.62, green: 0.12, blue: 0.05)])
        }
    }
}

// MARK: - Shared timing

func welcomeEase(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

extension WelcomeStop {
    /// How long the hero plays when you act on it, in seconds.
    var loop: Double {
        switch self {
        case .spaces: 7.5
        case .newTab, .commands: 4.2
        case .importing: 4
        case .tour: 10
        case .library, .makeDefault: 3
        case .agents: 6
        }
    }

    /// The still frame before you've done it.
    var rest: Double {
        switch self {
        case .tour: 0.6
        default: 0
        }
    }

    /// The still frame once it's done: the result.
    var doneRest: Double {
        switch self {
        case .importing: 0.95 * 4
        case .library, .makeDefault: 0.95 * 3
        case .agents: 0.9 * 6
        case .tour: 0.6
        default: 0
        }
    }
}

/// The hero for a stop. It rests on a still frame and only runs its clock while it plays, which
/// is only ever because the person did something, so it never fights them.
struct StopHero: View {
    let stop: WelcomeStop
    var scale: CGFloat = 1
    var playing = false
    var start: Date? = nil
    /// Spaces only: the space the person has swiped to.
    var spacePos: Double? = nil
    /// The still frame to rest on; the stop's own when nil.
    var rest: Double? = nil
    /// What the person picked: the browser, the kit or the agent.
    var choice: String? = nil
    /// Import only: what really came over.
    var result: ImportResult? = nil
    @State private var opened = Date.now

    var body: some View {
        if playing && !Motion.reduced {
            TimelineView(.animation) { context in
                frame(min(stop.loop * 0.999, context.date.timeIntervalSince(start ?? opened)), playing: true)
            }
        } else {
            frame(Motion.reduced && playing ? stop.doneRest : rest ?? stop.rest, playing: false)
        }
    }

    private func frame(_ t: Double, playing: Bool) -> some View {
        Group {
            switch stop {
            case .spaces: SpacesHero(t: t, pos: spacePos)
            case .newTab: ShortcutHero(t: t, letter: "T", mode: .newTab)
            case .commands: ShortcutHero(t: t, letter: "K", mode: .commands)
            case .importing: ImportHero(t: t, from: choice ?? "Chrome", result: result, playing: playing)
            case .tour: TourHero(t: t, playing: playing)
            case .library: LibraryHero(t: t, kit: choice ?? "Developer")
            case .agents: AgentsHero(t: t, agent: choice ?? "Claude Code")
            case .makeDefault: DefaultHero(t: t)
            }
        }
        .scaleEffect(scale)
        // Flattened into one Metal layer: one texture to composite instead of dozens of layers.
        // Padded first so the heroes' shadows aren't clipped by the flattened bounds.
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }
}

/// The browsers people come from, with their favicon stand-ins.
enum WelcomeBrowsers {
    static let all: [(name: String, letter: String, color: Color)] = [
        ("Chrome", "C", Color(red: 0.86, green: 0.27, blue: 0.22)), ("Safari", "S", Color(red: 0.16, green: 0.5, blue: 0.95)),
        ("Arc", "A", Color(red: 0.93, green: 0.3, blue: 0.5)), ("Edge", "E", Color(red: 0.05, green: 0.55, blue: 0.75)),
        ("Brave", "B", Color(red: 0.98, green: 0.38, blue: 0.15)), ("Vivaldi", "V", Color(red: 0.86, green: 0.2, blue: 0.24)),
    ]
    static func info(_ name: String) -> (name: String, letter: String, color: Color) { all.first { $0.name == name } ?? all[0] }
}

enum WelcomeKits {
    static let all: [(name: String, items: [(String, String, Color)])] = [
        ("Developer", [("JSON Viewer", "curlybraces", .orange), ("React Tools", "atom", .cyan),
                       ("Radar", "dot.radiowaves.left.and.right", .green), ("Notes", "note.text", .yellow)]),
        ("Agents", [("MCP Bridge", "point.3.connected.trianglepath.dotted", .purple), ("Agent Space", "pointer.arrow.ipad.rays", .indigo),
                    ("Notes", "note.text", .yellow), ("Screenshots", "camera.viewfinder", .teal)]),
        ("Writer", [("Reader", "book", .brown), ("Clipper", "scissors", .pink),
                    ("Grammar", "textformat.abc", .green), ("Dictionary", "character.book.closed", .blue)]),
    ]
}

enum WelcomeAgents {
    static let all = ["Claude Code", "Codex", "Cursor"]
    static func command(_ agent: String) -> String {
        switch agent {
        case "Codex": "codex mcp add browsa"
        case "Cursor": "cursor --add-mcp browsa"
        default: "claude mcp add browsa"
        }
    }
}

// MARK: - Little pieces of real UI

/// A favicon stand-in: the site's initial on its brand-ish colour.
struct MiniFavicon: View {
    let letter: String
    let color: Color
    var size: CGFloat = 14
    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: .rect(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A sidebar tab row as Browsa draws it.
struct MiniTabRow: View {
    let title: String
    let letter: String
    let color: Color
    var selected = false
    var body: some View {
        HStack(spacing: 7) {
            MiniFavicon(letter: letter, color: color, size: 13)
            Text(title).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(selected ? AnyShapeStyle(.background.opacity(0.85)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1, y: 0.5)
    }
}

/// A Browsa window in miniature: traffic lights, tinted sidebar, the page card.
struct MiniWindow<Sidebar: View, Page: View>: View {
    var tint: Color = .clear
    var sidebarWidth: CGFloat = 118
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let page: Page

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 8).padding(.leading, 3)
                sidebar
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: sidebarWidth)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
                .padding(5)
        }
        .background {
            ZStack {
                Rectangle().fill(PanelFill())
                tint.opacity(0.14)
            }
        }
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

/// Grey lines standing in for a page's text.
/// A web page in miniature: a banner in the space's colour, a heading, a few lines
/// and two cards. Each space's page is laid out a little differently.
struct MiniPage: View {
    let accent: Color
    var seed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: seed == 1 ? 30 : 40)
                .overlay(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).frame(width: 54, height: 6).padding(7)
                }
            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.22)).frame(width: [92, 70, 84][seed % 3], height: 6)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([0.95, 0.8, 0.88], id: \.self) { w in
                    GeometryReader { g in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08)).frame(width: g.size.width * w, height: 4) }
                        .frame(height: 4)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(accent.opacity(i == 0 ? 0.3 : 0.16)).frame(height: 18)
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.14)).frame(width: 34, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.07)).frame(width: 46, height: 3)
                    }
                    .padding(5)
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 5, style: .continuous))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
    }
}

struct PageLines: View {
    var widths: [CGFloat] = [0.9, 0.75, 0.82, 0.6, 0.7]
    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.18)).frame(width: g.size.width * 0.5, height: 7)
                ForEach(widths.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08)).frame(width: g.size.width * widths[i], height: 5)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Magic Keyboard

/// A Magic Keyboard key, white or space grey, that presses down.
struct MagicKey: View {
    let label: String
    var symbol: String? = nil
    var width: CGFloat = 38
    var pressed = false
    var lit = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: dark ? [Color(white: 0.2), Color(white: 0.15)] : [Color(white: 1), Color(white: 0.955)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.12 : 0.9), .black.opacity(dark ? 0.4 : 0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            if let symbol {
                // Modifier keys: the symbol top right, the name bottom left, as printed on the keyboard.
                Text(symbol).font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
                Text(label).font(.system(size: 7.5)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
            } else {
                Text(label).font(.system(size: label.count > 1 ? 7.5 : 13.5, weight: .regular))
            }
        }
        .foregroundStyle(dark ? Color(white: 0.88) : Color(white: 0.2))
        .frame(width: width, height: 36)
        .brightness(pressed ? -0.035 : 0)
        .shadow(color: .black.opacity(dark ? 0.6 : 0.22), radius: pressed ? 0.3 : 0.8, y: pressed ? 0.3 : 1.3)
        .offset(y: pressed ? 1.2 : 0)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.45, blue: 0.12).opacity(pressed ? 0.55 : 0))
                    .blur(radius: 8)
                    .padding(-4)
            }
        }
    }
}

/// A slice of a Magic Keyboard around the keys a shortcut uses.
struct KeyboardSlice: View {
    let letter: String
    let commandDown: Bool
    let letterDown: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let left = letter == "T"
        let rows: [[String]] = left
            ? [["Q", "W", "E", "R", "T", "Y", "U"], ["A", "S", "D", "F", "G", "H", "J"], ["Z", "X", "C", "V", "B", "N", "M"]]
            : [["T", "Y", "U", "I", "O", "P", "["], ["G", "H", "J", "K", "L", ";", "'"], ["B", "N", "M", ",", ".", "/", "⇧"]]
        let stagger: [CGFloat] = left ? [0, 10, 30] : [0, 10, 30]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r], id: \.self) { k in
                        MagicKey(label: k, pressed: k == letter && letterDown, lit: k == letter)
                    }
                }
                .padding(.leading, stagger[r])
            }
            HStack(spacing: 4) {
                if left {
                    MagicKey(label: "control", symbol: "⌃", width: 42)
                    MagicKey(label: "option", symbol: "⌥", width: 42)
                    MagicKey(label: "command", symbol: "⌘", width: 52, pressed: commandDown, lit: true)
                    MagicKey(label: "", width: 190)
                } else {
                    MagicKey(label: "", width: 150)
                    MagicKey(label: "command", symbol: "⌘", width: 52, pressed: commandDown, lit: true)
                    MagicKey(label: "option", symbol: "⌥", width: 42)
                }
            }
            .padding(.leading, left ? 0 : 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: scheme == .dark ? [Color(white: 0.3), Color(white: 0.22)] : [Color(white: 0.9), Color(white: 0.8)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Brushed(dark: scheme == .dark).clipShape(.rect(cornerRadius: 12, style: .continuous)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }
}

/// Browsa's command bar in miniature.
struct MiniCommandBar: View {
    let typed: String
    let mode: CommandBarMode
    let highlighted: Int

    private var rows: [(icon: AnyView, title: String, sub: String?, hint: String?)] {
        if mode == .commands {
            return [
                (AnyView(Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)), "Radar", "Your local dev servers", nil),
                (AnyView(Image(systemName: "text.bubble.fill").foregroundStyle(.yellow)), "Comment on Page", "Notes", nil),
                (AnyView(Image(systemName: "pointer.arrow.ipad.rays").foregroundStyle(.orange)), "Agents", nil, nil),
            ]
        }
        return [
            (AnyView(MiniFavicon(letter: "G", color: Color(white: 0.12), size: 15)), "jmaorr/Browsa", "github.com", nil),
            (AnyView(Image(systemName: "square.on.square").foregroundStyle(.secondary)), "GitHub Actions", "Switch to Tab", nil),
            (AnyView(Image(systemName: "magnifyingglass").foregroundStyle(.secondary)), "github browsa", nil, nil),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .commands ? "command" : "magnifyingglass")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text(typed.isEmpty ? (mode == .commands ? "Open a tool or run a command" : "Search or enter address") : typed)
                        .foregroundStyle(typed.isEmpty ? .tertiary : .primary)
                    Rectangle().fill(Color.accentColor).frame(width: 1.2, height: 13)
                }
                .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.6)
            VStack(spacing: 1) {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(spacing: 9) {
                        r.icon.frame(width: 15, height: 15).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 11.5))
                            if let sub = r.sub { Text(sub).font(.system(size: 9.5)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if let hint = r.hint { Text(hint).font(.system(size: 9.5)).foregroundStyle(.secondary) }
                        if i == highlighted { Image(systemName: "return").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: r.sub == nil ? 26 : 32)
                    .background(i == highlighted ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(5)
        }
        .frame(width: 250)
        .background(PanelFill(), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

// MARK: - Heroes

/// ⌘T or ⌘K pressed on a real keyboard, then the command bar it opens.
private struct ShortcutHero: View {
    let t: Double
    let letter: String
    let mode: CommandBarMode

    var body: some View {
        let period = 4.2, f = t.truncatingRemainder(dividingBy: period) / period
        let cmd = f > 0.14 && f < 0.42, key = f > 0.2 && f < 0.36
        let barIn = welcomeEase((f - 0.26) / 0.06) * (1 - welcomeEase((f - 0.9) / 0.08))
        let text = mode == .commands ? "radar" : "github"
        let n = Int(Double(text.count) * welcomeEase((f - 0.4) / 0.22))
        ZStack {
            KeyboardSlice(letter: letter, commandDown: cmd, letterDown: key)
                .scaleEffect(0.86)
                .offset(y: 22)
                .blur(radius: 3 * barIn)
                .opacity(1 - 0.35 * barIn)
            MiniCommandBar(typed: String(text.prefix(n)), mode: mode, highlighted: n == text.count ? 0 : -1)
                .scaleEffect(0.78 + 0.08 * barIn)
                .opacity(barIn)
                .offset(y: -8 - 8 * (1 - barIn))
        }
    }
}

/// A Browsa window whose sidebar swipes between three spaces, each with its own tint and tabs.
private struct SpacesHero: View, @MainActor Animatable {
    let t: Double
    /// When set, the person is driving it: which space is showing, fractional mid-switch.
    var pos: Double?
    var animatableData: Double {
        get { pos ?? 0 }
        set { if pos != nil { pos = newValue } }
    }

    typealias Space = (name: String, symbol: String, color: Color, tabs: [(String, String, Color)])
    static let spaces: [Space] = [
        ("Work", "briefcase.fill", .orange, [("Linear", "L", .indigo), ("Figma", "F", .purple), ("PR #42 · checkout", "G", Color(white: 0.15)),
                                              ("Standup notes", "N", .yellow), ("Sentry", "S", .pink), ("Calendar", "C", .red), ("Roadmap", "R", .blue)]),
        ("Personal", "house.fill", .green, [("Welcome", "W", .orange), ("Recipes", "R", .green), ("YouTube", "Y", .red),
                                             ("Flights to Tokyo", "F", .blue), ("Bank", "B", .teal), ("Spotify", "S", .green), ("News", "N", Color(white: 0.3))]),
        ("Side project", "hammer.fill", .teal, [("localhost:3000", "N", .black), ("Docs", "D", .teal), ("Deploys", "V", Color(white: 0.2)),
                                                 ("Stripe", "S", .indigo), ("Analytics", "A", .orange), ("GitHub Issues", "G", Color(white: 0.15)), ("Supabase", "S", .green)]),
    ]

    var body: some View {
        let period = 7.5, seg = period / 3
        let local = t.truncatingRemainder(dividingBy: period)
        let raw = pos ?? {
            let k = floor(local / seg)
            return k + welcomeEase(((local - k * seg) / seg - 0.72) / 0.28)
        }()
        let base = floor(raw), p = raw - base
        let k = ((Int(base) % 3) + 3) % 3
        let from = Self.spaces[k], to = Self.spaces[(k + 1) % 3]
        let showing = p < 0.5 ? k : (k + 1) % 3
        MiniWindow(tint: p < 0.5 ? from.color : to.color, sidebarWidth: 156) {
            HStack(spacing: 5) {
                ForEach([("Y", Color.red), ("G", Color(white: 0.15)), ("W", Color(white: 0.45)), ("M", Color.blue)], id: \.0) { f in
                    MiniFavicon(letter: f.0, color: f.1, size: 13)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.bottom, 8)
            ZStack(alignment: .topLeading) {
                list(from).offset(x: -150 * p).opacity(1 - p)
                list(to).offset(x: 150 * (1 - p)).opacity(p)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: Self.spaces[i].symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(i == showing ? AnyShapeStyle(Self.spaces[i].color) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } page: {
            MiniPage(accent: showing == 0 ? Self.spaces[0].color : showing == 1 ? Self.spaces[1].color : Self.spaces[2].color, seed: showing)
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 24)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func list(_ s: Space) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(s.name, systemImage: s.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(s.color)
                .padding(.horizontal, 6).padding(.bottom, 3)
            ForEach(s.tabs.indices, id: \.self) { i in
                MiniTabRow(title: s.tabs[i].0, letter: s.tabs[i].1, color: s.tabs[i].2, selected: i == 0)
            }
        }
    }
}

/// A macOS import sheet filling in as it brings things over.
private struct ImportHero: View {
    let t: Double
    let from: String
    /// Once imported, the real counts; until then, dashes.
    var result: ImportResult?
    var playing = false

    var body: some View {
        // While importing, the bar fills towards most of the way; the result finishes it.
        let prog = result != nil ? 1 : playing ? 0.85 * welcomeEase(t / 2.2) : 0
        let browser = WelcomeBrowsers.info(from)
        let items: [(String, String, Int?)] = [("Bookmarks", "bookmark", result?.bookmarks), ("History", "clock", result?.history),
                                               ("Favourites", "star", result?.favourites), ("Spaces", "sidebar.squares.left", result?.spaces)]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("Import from").font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    MiniFavicon(letter: browser.letter, color: browser.color, size: 13)
                    Text(browser.name).font(.system(size: 11)).fixedSize()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background, in: .rect(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            VStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    let it = items[i]
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.square.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        Image(systemName: it.1).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text(it.0).font(.system(size: 11))
                        Spacer()
                        Text(it.2.map { $0.formatted() } ?? "–")
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            // Drawn rather than an NSProgressIndicator, so it renders inside the flattened hero.
            Capsule().fill(.primary.opacity(0.1)).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(Color.accentColor).frame(width: g.size.width * prog) }
                }
            HStack {
                Spacer()
                Text(prog >= 1 ? "Done" : playing ? "Importing…" : "Import")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(playing && prog < 1 ? .secondary : Color.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(playing && prog < 1 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor), in: .capsule)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(PanelFill(), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

/// A short reel of real features in a Browsa window: Reader, a note, Radar, an agent.
private struct TourHero: View {
    let t: Double
    var playing = false

    var body: some View {
        let period = 10.0, local = t.truncatingRemainder(dividingBy: period)
        let scene = Int(local / 2.5), f = (local - Double(scene) * 2.5) / 2.5
        let titles = ["Reader", "Notes on any page", "Radar", "Agents"]
        VStack(spacing: 8) {
            MiniWindow(tint: .pink, sidebarWidth: 92) {
                ForEach(0..<4, id: \.self) { i in
                    MiniTabRow(title: ["Docs", "Shop", "Notes", "Agent"][i], letter: ["D", "S", "N", "A"][i],
                               color: [.blue, .orange, .yellow, .purple][i], selected: i == scene)
                }
            } page: {
                Group {
                    switch scene {
                    case 0:
                        // Reader: the page's clutter falls away, leaving the article.
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.3)).frame(width: 110, height: 7)
                            ForEach([0.95, 0.9, 0.97, 0.85, 0.92, 0.6], id: \.self) { w in
                                GeometryReader { g in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.12)).frame(width: g.size.width * w, height: 4) }
                                    .frame(height: 4)
                            }
                        }
                        .padding(.horizontal, 26).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color(red: 0.98, green: 0.96, blue: 0.91).opacity(welcomeEase(f / 0.4)))
                    case 1:
                        PageLines().overlay(alignment: .topTrailing) {
                            Text("Swap this for\nthe new pricing")
                                .font(.system(size: 8.5, weight: .medium))
                                .padding(6)
                                .background(Color.yellow.opacity(0.9), in: .rect(cornerRadius: 6, style: .continuous))
                                .foregroundStyle(.black)
                                .padding(8)
                                .scaleEffect(welcomeEase(f / 0.25), anchor: .topTrailing)
                        }
                    case 2:
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(["localhost:3000  next dev", "localhost:5173  vite", "localhost:8787  wrangler"], id: \.self) { s in
                                HStack(spacing: 6) {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                    Text(s).font(.system(size: 9, design: .monospaced))
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    default:
                        PageLines().overlay {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.purple)
                                .offset(x: -30 + 60 * welcomeEase(f / 0.8), y: 10 - 20 * welcomeEase(f / 0.8))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.purple.opacity(0.6), lineWidth: 1.5))
                    }
                }
            }
            .frame(width: 310, height: 156)
            .overlay {
                if !playing {
                    // Paused: a big play button over the window, like a video.
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                }
            }
            // Player controls under the window, like a video.
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9))
                Text(titles[scene]).font(.system(size: 10.5, weight: .semibold))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(.white.opacity(0.25)).frame(width: 18, height: 3)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: 18 * (i < scene ? 1 : i == scene ? f : 0), height: 3)
                            }
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: 310)
        }
    }
}

/// The Library: a kit of verified extensions, one being added.
private struct LibraryHero: View {
    let t: Double
    let kit: String

    var body: some View {
        let f = t / 3
        let added = f > 0.25
        let items = (WelcomeKits.all.first { $0.name == kit } ?? WelcomeKits.all[0]).items
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(kit) kit").font(.system(size: 13, weight: .semibold))
                    Label("4 verified extensions", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(added ? "Added" : "Add Kit")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(added ? Color.secondary : Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(added ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor), in: .capsule)
                    .scaleEffect(f > 0.18 && f < 0.25 ? 0.92 : 1)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(items[0], on: f > 0.3); tile(items[1], on: f > 0.38) }
                GridRow { tile(items[2], on: f > 0.46); tile(items[3], on: f > 0.54) }
            }
        }
        .padding(12)
        .frame(width: 290)
        .background(.background, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }

    private func tile(_ it: (String, String, Color), on: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: it.1)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(LinearGradient(colors: [it.2, it.2.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                            in: .rect(cornerRadius: 6, style: .continuous))
            Text(it.0).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 11))
                .foregroundStyle(on ? Color.green : Color.secondary)
        }
        .padding(7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// A terminal adding Browsa's MCP server, then Claude Code working in the Agent space.
private struct AgentsHero: View {
    let t: Double
    let agent: String

    var body: some View {
        let f = t / 6
        let cmd = WelcomeAgents.command(agent)
        let n = Int(Double(cmd.count) * welcomeEase((f - 0.05) / 0.3))
        let connected = f > 0.42
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 7, height: 7)
                    }
                    Spacer()
                    Text("zsh").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.bottom, 6)
                HStack(spacing: 0) {
                    Text("~/checkout-web ").foregroundStyle(Color(red: 0.4, green: 0.8, blue: 0.95))
                    Text("❯ ").foregroundStyle(Color(red: 0.6, green: 0.9, blue: 0.5))
                    Text(String(cmd.prefix(n)))
                    if !connected { Rectangle().fill(.white.opacity(0.8)).frame(width: 6, height: 11).opacity(n == 0 || n == cmd.count ? 1 : 0.8) }
                }
                if connected {
                    Text("✓ Added Browsa to \(agent)").foregroundStyle(Color(red: 0.6, green: 0.9, blue: 0.5))
                    Text("  Browsa can open tabs, read pages and leave notes.").foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .padding(10)
            .frame(width: 250, height: 130, alignment: .topLeading)
            .background(Color(white: 0.09).opacity(0.92), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)

            // Browsa's Agents panel row lighting up once the agent connects.
            HStack(spacing: 7) {
                Image(systemName: "pointer.arrow.ipad.rays").font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent).font(.system(size: 10.5, weight: .semibold))
                    Text(f > 0.75 ? "Filling the checkout form" : "Connected").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Circle().fill(.green).frame(width: 6, height: 6)
            }
            .padding(9)
            .frame(width: 168)
            .background(PanelFill(), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .environment(\.colorScheme, .light)
            .offset(x: 30, y: 26)
            .opacity(welcomeEase((f - 0.45) / 0.08))
            .scaleEffect(0.9 + 0.1 * welcomeEase((f - 0.45) / 0.08), anchor: .bottomTrailing)
        }
    }
}

/// System Settings' default browser menu landing on Browsa, and the Savant medal.
private struct DefaultHero: View {
    let t: Double

    var body: some View {
        let f = t / 3
        let picked = f > 0.35
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("Default web browser").font(.system(size: 11.5)).fixedSize()
                Spacer()
                HStack(spacing: 5) {
                    if picked {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 15, height: 15)
                        Text("Browsa").font(.system(size: 11.5, weight: .medium))
                    } else {
                        Image(systemName: "safari").font(.system(size: 12)).foregroundStyle(.blue)
                        Text("Safari").font(.system(size: 11.5))
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background, in: .rect(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                .scaleEffect(f > 0.28 && f < 0.35 ? 0.95 : 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 280)
            .background(PanelFill(), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .environment(\.colorScheme, .light)

            ZStack {
                Circle().fill(AngularGradient(colors: [Color(red: 0.54, green: 0.23, blue: 0.03), Color(red: 0.96, green: 0.71, blue: 0.27),
                                                       Color(red: 1, green: 0.95, blue: 0.81), Color(red: 0.85, green: 0.54, blue: 0.11),
                                                       Color(red: 0.48, green: 0.17, blue: 0.03), Color(red: 0.94, green: 0.69, blue: 0.25),
                                                       Color(red: 1, green: 0.94, blue: 0.77), Color(red: 0.79, green: 0.45, blue: 0.07),
                                                       Color(red: 0.54, green: 0.23, blue: 0.03)], center: .center))
                    .rotationEffect(.degrees(t * 30))
                Circle().strokeBorder(Color(red: 1, green: 0.94, blue: 0.78).opacity(0.45), lineWidth: 4)
                Image(systemName: "star.fill").font(.system(size: 22)).foregroundStyle(Color(red: 0.36, green: 0.13, blue: 0.01).opacity(0.85))
            }
            .frame(width: 62, height: 62)
            .shadow(color: Color(red: 0.4, green: 0.12, blue: 0).opacity(0.5), radius: 10, y: 6)
            .scaleEffect(picked ? 1 : 0.6)
            .opacity(picked ? 1 : 0.0)
            .animation(.bouncy(duration: 0.5, extraBounce: 0.2), value: picked)
        }
    }
}
