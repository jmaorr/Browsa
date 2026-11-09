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

    /// Text on this surface: dark surfaces always take white.
    func isDark(_ scheme: ColorScheme) -> Bool {
        switch self {
        case .paper, .aluminium: scheme == .dark
        case .meshLight: false
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
        case .mesh(let c), .meshLight(let c):
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.5], [0.42, 0.58], [1, 0.42],
                [0, 1], [0.6, 1], [1, 1],
            ], colors: (0..<9).map { c[$0 % c.count] })
        case .grain(let a, let b):
            LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Grain(opacity: 0.09))
        case .aluminium:
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.26), Color(white: 0.18)] : [Color(white: 0.93), Color(white: 0.84)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(Brushed(dark: scheme == .dark))
        }
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
        case .spaces: .meshLight([Color(red: 0.99, green: 0.66, blue: 0.3), Color(red: 1.0, green: 0.86, blue: 0.42),
                                  Color(red: 0.62, green: 0.86, blue: 0.5), Color(red: 0.98, green: 0.76, blue: 0.36)])
        case .newTab: .paper
        case .commands: .aluminium
        case .importing: .paper
        case .tour: .grain(Color(red: 0.36, green: 0.06, blue: 0.16), Color(red: 0.12, green: 0.04, blue: 0.1))
        case .library: .paper
        case .agents: .grain(Color(red: 0.08, green: 0.1, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.06))
        case .makeDefault: .mesh([Color(red: 0.98, green: 0.62, blue: 0.2), Color(red: 0.86, green: 0.25, blue: 0.08),
                                  Color(red: 0.99, green: 0.83, blue: 0.45), Color(red: 0.62, green: 0.12, blue: 0.05)])
        }
    }
}

// MARK: - Shared timing

func welcomeEase(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

extension WelcomeStop {
    /// How long the hero's loop runs, in seconds.
    var loop: Double {
        switch self {
        case .spaces: 7.5
        case .newTab, .commands: 4.2
        case .importing: 6
        case .tour: 10
        case .library, .makeDefault: 5
        case .agents: 7
        }
    }

    /// The still frame a hero rests on: the moment that best shows what it teaches.
    var rest: Double {
        switch self {
        case .spaces: 1.0
        case .newTab, .commands: 0
        case .importing: 0.9 * 6
        case .tour: 3.2
        case .library: 0.85 * 5
        case .agents: 0.82 * 7
        case .makeDefault: 0.75 * 5
        }
    }
}

/// The hero for a stop. It rests on a still frame and only runs its clock while playing, so a
/// page of cards costs nothing when nobody is looking at one.
struct StopHero: View {
    let stop: WelcomeStop
    var scale: CGFloat = 1
    var playing = false
    var start: Date? = nil
    /// Spaces only: the space the person has swiped to.
    var spacePos: Double? = nil
    @State private var opened = Date.now

    var body: some View {
        if playing && !Motion.reduced {
            TimelineView(.animation) { context in
                // Starts from the still frame, so playing and resting line up.
                frame(stop.rest + context.date.timeIntervalSince(start ?? opened))
            }
        } else {
            frame(stop.rest)
        }
    }

    private func frame(_ t: Double) -> some View {
        Group {
            switch stop {
            case .spaces: SpacesHero(t: t, pos: spacePos)
            case .newTab: ShortcutHero(t: t, letter: "T", mode: .newTab)
            case .commands: ShortcutHero(t: t, letter: "K", mode: .commands)
            case .importing: ImportHero(t: t)
            case .tour: TourHero(t: t)
            case .library: LibraryHero(t: t)
            case .agents: AgentsHero(t: t)
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
/// A web page in miniature: an address bar, a banner in the space's colour, a heading, a few lines
/// and two cards. Each space's page is laid out a little differently.
struct MiniPage: View {
    let accent: Color
    var seed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(accent.opacity(0.8)).frame(width: 7, height: 7)
                Capsule().fill(.primary.opacity(0.07)).frame(width: 70, height: 7)
                Spacer()
                Capsule().fill(.primary.opacity(0.07)).frame(width: 22, height: 7)
            }
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
                (AnyView(Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary)), "Split View", nil, "⌃⌘S"),
                (AnyView(Image(systemName: "pin").foregroundStyle(.secondary)), "Pin Tab", nil, "⌘D"),
                (AnyView(Image(systemName: "pointer.arrow.ipad.rays").foregroundStyle(.secondary)), "Ask an Agent", nil, nil),
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
        let text = mode == .commands ? "split" : "github"
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
                                              ("Standup notes", "N", .yellow), ("Sentry", "S", .pink)]),
        ("Personal", "house.fill", .green, [("Welcome", "W", .orange), ("Recipes", "R", .green), ("YouTube", "Y", .red),
                                             ("Flights to Tokyo", "F", .blue), ("Bank", "B", .teal)]),
        ("Side project", "hammer.fill", .teal, [("localhost:3000", "N", .black), ("Docs", "D", .teal), ("Deploys", "V", Color(white: 0.2)),
                                                 ("Stripe", "S", .indigo), ("Analytics", "A", .orange)]),
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

    var body: some View {
        let period = 6.0, f = t.truncatingRemainder(dividingBy: period) / period
        let prog = welcomeEase((f - 0.15) / 0.55)
        let items: [(String, String, Int)] = [("Bookmarks", "bookmark", 1284), ("History", "clock", 212), ("Passwords", "key", 46), ("Open tabs", "square.on.square", 9)]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("Import from").font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    MiniFavicon(letter: "C", color: Color(red: 0.86, green: 0.27, blue: 0.22), size: 13)
                    Text("Chrome").font(.system(size: 11)).fixedSize()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background, in: .rect(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            VStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    let it = items[i]
                    let share = welcomeEase((prog - Double(i) * 0.15) / 0.45)
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.square.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        Image(systemName: it.1).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text(it.0).font(.system(size: 11))
                        Spacer()
                        Text(Int(Double(it.2) * share).formatted()).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
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
                Text(prog >= 1 ? "Done" : "Importing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(prog >= 1 ? .white : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(prog >= 1 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .capsule)
            }
        }
        .padding(14)
        .frame(width: 236)
        .background(PanelFill(), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

/// A short reel of real features in a Browsa window: split view, a note, Radar, an agent.
private struct TourHero: View {
    let t: Double

    var body: some View {
        let period = 10.0, local = t.truncatingRemainder(dividingBy: period)
        let scene = Int(local / 2.5), f = (local - Double(scene) * 2.5) / 2.5
        let titles = ["Split view", "Notes on any page", "Radar", "Agents"]
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
                        HStack(spacing: 4) {
                            PageLines().background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 4))
                            PageLines(widths: [0.6, 0.8, 0.5])
                                .background(Color.blue.opacity(0.05), in: .rect(cornerRadius: 4))
                                .frame(maxWidth: 40 + 60 * welcomeEase(f / 0.4))
                        }
                        .padding(3)
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
            // Player controls under the window, like a video.
            HStack(spacing: 8) {
                Image(systemName: "pause.fill").font(.system(size: 9))
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
    private let items: [(String, String, Color)] = [
        ("JSON Viewer", "curlybraces", .orange), ("React Tools", "atom", .cyan),
        ("Radar", "dot.radiowaves.left.and.right", .green), ("Notes", "note.text", .yellow),
    ]

    var body: some View {
        let period = 5.0, f = t.truncatingRemainder(dividingBy: period) / period
        let added = f > 0.45
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Developer kit").font(.system(size: 13, weight: .semibold))
                    Label("4 verified extensions", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(added ? "Added" : "Add Kit")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(added ? Color.secondary : Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(added ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor), in: .capsule)
                    .scaleEffect(f > 0.4 && f < 0.45 ? 0.92 : 1)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(0, f); tile(1, f) }
                GridRow { tile(2, f); tile(3, f) }
            }
        }
        .padding(12)
        .frame(width: 290)
        .background(.background, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }

    private func tile(_ i: Int, _ f: Double) -> some View {
        let it = items[i]
        let on = f > 0.5 + Double(i) * 0.06
        return HStack(spacing: 7) {
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

    var body: some View {
        let period = 7.0, f = t.truncatingRemainder(dividingBy: period) / period
        let cmd = "claude mcp add browsa"
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
                    if !connected { Rectangle().fill(.white.opacity(0.8)).frame(width: 6, height: 11) }
                }
                if connected {
                    Text("✓ Added Browsa (localhost:47913)").foregroundStyle(Color(red: 0.6, green: 0.9, blue: 0.5))
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
                    Text("Claude Code").font(.system(size: 10.5, weight: .semibold))
                    Text(f > 0.6 ? "Filling the checkout form" : "Connected").font(.system(size: 9)).foregroundStyle(.secondary)
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
        let period = 5.0, f = t.truncatingRemainder(dividingBy: period) / period
        let picked = f > 0.42
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
                .scaleEffect(f > 0.36 && f < 0.42 ? 0.95 : 1)
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
