import SwiftUI
import AppKit

// MARK: - Intro

/// The metal's own clock, so the intro can slow it to a crawl as the page lands.
@MainActor final class MetalClock {
    private(set) var time = 0.0
    private var speed = 1.0
    private var last: Date?

    func advance(to date: Date, slowing: Bool) -> Double {
        let dt = last.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        speed += ((slowing ? 0.12 : 1.0) - speed) * min(1, dt * 0.75)
        time += dt * speed
        return time
    }
}

/// The intro over the whole window: liquid metal grows out of the page colour and fills the
/// window, the title blurs in, then the frame pulls onto the page card and the metal fades away
/// under the rising page. It ends exactly on the real card.
struct IntroOverlay: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var colorScheme
    let phase: IntroPhase
    @State private var clock = MetalClock()
    @State private var titleShown = false

    var body: some View {
        GeometryReader { proxy in
            let full = CGRect(origin: .zero, size: proxy.size)
            let settling = phase >= .settle
            let card = browser.pageCardFrame() ?? full.insetBy(dx: PageCard.inset, dy: PageCard.inset)
            let rect = settling ? card : full
            let base = WelcomePalette.pageRGB(colorScheme)
            ZStack(alignment: .topLeading) {
                // The metal is drawn at the frame's own size, so it scales down with the frame
                // as it pulls onto the page card rather than being cropped by it.
                GeometryReader { frame in
                    TimelineView(.animation) { context in
                        let t = clock.advance(to: context.date, slowing: settling)
                        Rectangle()
                            .colorEffect(ShaderLibrary.twinMetal(.float2(frame.size), .float(t),
                                                                 .float3(base.x, base.y, base.z), .float(0.22)))
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(.rect(cornerRadius: settling ? PageCard.radius : 0, style: .continuous))
                .offset(x: rect.minX, y: rect.minY)
                .animation(IntroPhase.settleCurve, value: settling)
                Text("Welcome to Browsa")
                    .font(.system(size: 60, weight: .semibold))
                    .tracking(-2)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.17, green: 0.07, blue: 0.03))
                    .shadow(color: colorScheme == .dark ? Color(red: 0.47, green: 0.08, blue: 0).opacity(0.3) : .white.opacity(0.5),
                            radius: 15, y: 2)
                    .blur(radius: titleShown && !settling ? 0 : 24)
                    .opacity(titleShown && !settling ? 1 : 0)
                    .animation(.easeOut(duration: 0.9), value: settling)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .opacity(phase >= .cards ? 0 : 1)
            .animation(.easeInOut(duration: IntroPhase.fadeDuration), value: phase >= .cards)
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .allowsHitTesting(phase < .cards)
        .onTapGesture { browser.skipIntro() }
        .task {
            try? await Task.sleep(for: .seconds(IntroPhase.titleDelay))
            withAnimation(.easeOut(duration: 1.2)) { titleShown = true }
        }
        .accessibilityLabel("Welcome to Browsa")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the introduction")
    }
}

enum WelcomePalette {
    /// The page colour in sRGB, for the metal to grow out of.
    static func pageRGB(_ scheme: ColorScheme) -> SIMD3<Float> {
        var out = SIMD3<Float>(1, 1, 1)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let c = NSColor.textBackgroundColor.usingColorSpace(.sRGB) {
                out = SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
            }
        }
        return out
    }

    /// The orb's heat colours, oxblood to yellow.
    static let heat = LinearGradient(colors: [Color(red: 0.62, green: 0.09, blue: 0.02), Color(red: 0.78, green: 0.16, blue: 0.04),
                                              Color(red: 0.94, green: 0.54, blue: 0.07), Color(red: 0.95, green: 0.76, blue: 0.11)],
                                     startPoint: .leading, endPoint: .trailing)
    static let metal = AngularGradient(colors: [Color(red: 0.62, green: 0.09, blue: 0.02), Color(red: 0.94, green: 0.54, blue: 0.07),
                                                Color(red: 1, green: 0.88, blue: 0.54), Color(red: 0.91, green: 0.33, blue: 0.1),
                                                Color(red: 0.62, green: 0.09, blue: 0.02)], center: .center, angle: .degrees(210))
}

// MARK: - Stops and levels

/// The getting-started stops, in order. The three passive habits make you a Pro; bringing your
/// things over, the tour and the Library make you a Master; agents and the default browser finish it.
enum WelcomeStop: String, CaseIterable, Identifiable {
    case spaces, newTab, commands, importing, tour, library, agents, makeDefault
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaces: "Spaces"
        case .newTab: "⌘T opens anything"
        case .commands: "⌘K for everything"
        case .importing: "Bring your stuff"
        case .tour: "See it in action"
        case .library: "Built for the hustle"
        case .agents: "Let your agents in"
        case .makeDefault: "Make it yours"
        }
    }

    var detail: String {
        switch self {
        case .spaces: "Work, side project, personal. Each space keeps its own tabs and its own colour. Swipe with two fingers to switch."
        case .newTab: "Search, type an address, or jump to a tab you already have open."
        case .commands: "Split the view, pin a tab, ask an agent. Everything is a few letters away."
        case .importing: "Bookmarks, history, saved passwords and your open tabs, brought over in one go. Your old browser stays as it was."
        case .tour: "Split view, notes on any page, Radar for your dev servers, and agents in their own space. Just watch."
        case .library: "Hand-picked, verified extensions bundled into kits. Set Browsa up for coding or for agents in one click."
        case .agents: "Browsa runs an MCP server on your Mac. Add it to your coding agent and it can open tabs, read pages and leave notes."
        case .makeDefault: "Links from Mail, Slack and everywhere else open here. Finish this one to reach Savant."
        }
    }

    /// The opened card's headline, and its one real challenge.
    var headline: String {
        switch self {
        case .spaces: "One window, many lives"
        case .newTab: "Open anything from one bar"
        case .commands: "Every tool, one shortcut"
        case .importing: "Everything comes with you"
        case .tour: "A quick look at the rest"
        case .library: "Built for the hustle"
        case .agents: "Your agents can browse too"
        case .makeDefault: "Make Browsa your browser"
        }
    }

    var challenge: String {
        switch self {
        case .spaces: "Swipe to another space and back"
        case .newTab: "Press ⌘T"
        case .commands: "Press ⌘K"
        case .importing: "Import from another browser"
        case .tour: "Watch the tour"
        case .library: "Add a kit from the Library"
        case .agents: "Connect an agent"
        case .makeDefault: "Set Browsa as your default browser"
        }
    }

    var time: String {
        switch self {
        case .newTab, .commands, .makeDefault: "10 sec"
        case .spaces: "30 sec"
        case .tour: "40 sec"
        case .importing, .library, .agents: "1 min"
        }
    }

    var symbol: String {
        switch self {
        case .spaces: "sidebar.squares.left"
        case .newTab: "magnifyingglass"
        case .commands: "command"
        case .importing: "square.and.arrow.down"
        case .tour: "play.fill"
        case .library: "square.grid.2x2.fill"
        case .agents: "pointer.arrow.ipad.rays"
        case .makeDefault: "star.fill"
        }
    }

    /// Each card's own hue, 0…1.
    var hue: Double {
        switch self {
        case .spaces: 0.59
        case .newTab: 0.04
        case .commands: 0.74
        case .importing: 0.07
        case .tour: 0.92
        case .library: 0.42
        case .agents: 0.54
        case .makeDefault: 0.11
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum WelcomeLevel: Int, CaseIterable {
    case rookie, pro, master, savant

    var name: String { ["Rookie", "Pro", "Master", "Savant"][rawValue] }
    /// Stops done to reach it.
    var threshold: Int { [0, 3, 6, 8][rawValue] }
    var symbol: String { ["circle.fill", "bolt.fill", "flame.fill", "star.fill"][rawValue] }

    static func level(for done: Int) -> WelcomeLevel { allCases.last { done >= $0.threshold } ?? .rookie }
}

/// Which stops are done. Stored, so the bar remembers between launches.
@MainActor @Observable final class WelcomeProgress {
    static let shared = WelcomeProgress()
    private static let key = "welcomeStopsDone"
    private(set) var done: Set<WelcomeStop>

    private init() {
        done = Set((UserDefaults.standard.stringArray(forKey: Self.key) ?? []).compactMap(WelcomeStop.init(rawValue:)))
    }

    var level: WelcomeLevel { .level(for: done.count) }

    /// Marks a stop done; returns the new level if this one reached it.
    @discardableResult func complete(_ stop: WelcomeStop) -> WelcomeLevel? {
        guard !done.contains(stop) else { return nil }
        let before = level
        withAnimation(.smooth(duration: 0.8)) { done.insert(stop) }
        UserDefaults.standard.set(done.map(\.rawValue), forKey: Self.key)
        return level != before ? level : nil
    }

    func reset() {
        done = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: - The page

/// The welcome tab's page: a title, the level bar, and a gallery of stops. During the intro it
/// waits for the metal to start fading, then rises.
struct WelcomePage: View {
    @Environment(Browser.self) private var browser
    @State private var progress = WelcomeProgress.shared
    @State private var open: WelcomeStop?

    private var shown: Bool { browser.intro == nil || browser.intro == .cards }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("Make Browsa yours")
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.7)
                        Text("Eight short stops, about four minutes. Skip any of them.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .welcomeArrival(0, shown: shown)
                    LevelBar(done: progress.done.count)
                        .welcomeArrival(1, shown: shown)
                    gallery
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 30)
                .padding(.top, 44)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            if let stop = open {
                StopSheet(stop: stop, progress: progress, open: $open, complete: complete)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.smooth(duration: 0.35), value: open)
        .onChange(of: browser.intro) { _, phase in
            if phase == .fill { open = nil }
        }
        .onKeyPress(.escape) {
            guard open != nil else { return .ignored }
            open = nil
            return .handled
        }
        .onChange(of: browser.commandBar) { _, mode in
            if mode == .newTab { complete(.newTab) }
            if mode == .commands { complete(.commands) }
        }
    }

    private var gallery: some View {
        VStack(spacing: 12) {
            card(.spaces, 2)
            HStack(alignment: .top, spacing: 12) {
                card(.newTab, 3, vertical: true)
                card(.commands, 3.5, vertical: true)
            }
            card(.importing, 4)
            card(.tour, 5)
            card(.library, 6)
            card(.agents, 7)
            card(.makeDefault, 8)
        }
    }

    private func card(_ stop: WelcomeStop, _ order: Double, vertical: Bool = false) -> some View {
        GalleryCard(stop: stop, vertical: vertical, done: progress.done.contains(stop)) { open = stop }
            .welcomeArrival(order, shown: shown, distance: 22)
    }

    private func complete(_ stop: WelcomeStop) {
        if let level = progress.complete(stop) { browser.showToast("New level · \(level.name)") }
    }

    /// Asks macOS to make Browsa the default browser. macOS confirms with the person first.
    static func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
    }
}

// MARK: - Level bar

/// One segment per stop, with the levels as badges on the bar and their names beneath.
private struct LevelBar: View {
    let done: Int

    var body: some View {
        let current = WelcomeLevel.level(for: done)
        HStack(spacing: 4) {
            ForEach(WelcomeLevel.allCases, id: \.self) { level in
                if level != .rookie {
                    ForEach(WelcomeLevel(rawValue: level.rawValue - 1)!.threshold..<level.threshold, id: \.self) { i in
                        Segment(filled: i < done)
                    }
                }
                Badge(level: level, reached: done >= level.threshold, current: level == current)
            }
        }
        .padding(.bottom, 22)
    }

    private struct Segment: View {
        let filled: Bool
        var body: some View {
            Capsule()
                .fill(.quaternary.opacity(0.6))
                .overlay(alignment: .leading) {
                    Capsule().fill(WelcomePalette.heat)
                        .scaleEffect(x: filled ? 1 : 0, anchor: .leading)
                }
                .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
                .frame(height: 7)
                .animation(.smooth(duration: 0.8), value: filled)
        }
    }

    private struct Badge: View {
        let level: WelcomeLevel
        let reached: Bool
        let current: Bool
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ZStack {
                Circle().fill(reached ? AnyShapeStyle(WelcomePalette.metal) : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
                Circle().strokeBorder(reached ? Color(red: 1, green: 0.94, blue: 0.78).opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1.5)
                Image(systemName: level.symbol)
                    .font(.system(size: level == .rookie ? 6 : 10, weight: .bold))
                    .foregroundStyle(reached ? Color.white : Color.secondary)
            }
            .frame(width: 24, height: 24)
            .shadow(color: reached ? Color(red: 0.78, green: 0.16, blue: 0.04).opacity(0.45) : .clear, radius: 6, y: 3)
            .scaleEffect(reached ? 1 : 0.92)
            .animation(.bouncy(duration: 0.5, extraBounce: 0.25), value: reached)
            .overlay(alignment: level == .rookie ? .topLeading : level == .savant ? .topTrailing : .top) {
                label.fixedSize().offset(y: 30)
            }
        }

        private var label: some View {
            (current ? Text("Level \(level.rawValue + 1) · ").foregroundStyle(.secondary).fontWeight(.regular) : Text(""))
                + Text(level.name).foregroundStyle(reached ? .primary : .secondary)
        }
    }
}

// MARK: - Gallery cards

/// A card's colours, from its hue, for light and dark.
struct CardTint {
    let hue: Double
    let dark: Bool

    var top: Color { dark ? Color(hue: hue, saturation: 0.5, brightness: 0.2) : Color(hue: hue, saturation: 0.05, brightness: 1) }
    var bottom: Color { dark ? Color(hue: hue, saturation: 0.55, brightness: 0.12) : Color(hue: hue, saturation: 0.15, brightness: 0.97) }
    var glow: Color { Color(hue: hue, saturation: dark ? 0.8 : 0.6, brightness: dark ? 0.9 : 1).opacity(dark ? 0.35 : 0.3) }
    var line: Color { Color(hue: hue, saturation: 0.4, brightness: dark ? 0.75 : 0.7).opacity(dark ? 0.22 : 0.4) }
    var ink: Color { Color(hue: hue, saturation: dark ? 0.5 : 0.75, brightness: dark ? 1 : 0.62) }
    var muted: Color { Color(hue: hue, saturation: dark ? 0.12 : 0.22, brightness: dark ? 0.8 : 0.38) }
    var chip: Color { dark ? Color(hue: hue, saturation: 0.4, brightness: 0.34).opacity(0.6) : Color.white.opacity(0.78) }
    var tile: LinearGradient {
        LinearGradient(colors: [Color(hue: hue, saturation: 0.62, brightness: 0.95), Color(hue: hue, saturation: 0.78, brightness: 0.68)],
                       startPoint: .top, endPoint: .bottom)
    }

    var background: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [glow, .clear], center: UnitPoint(x: 0.85, y: 0.6), startRadius: 0, endRadius: 260)
        }
    }
}

private struct GalleryCard: View {
    let stop: WelcomeStop
    let vertical: Bool
    let done: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let tint = CardTint(hue: stop.hue, dark: colorScheme == .dark)
        Button(action: action) {
            Group {
                if vertical {
                    VStack(spacing: 0) {
                        text(tint)
                        Rectangle().fill(tint.line).frame(height: 1)
                        StopArt(stop: stop, tint: tint).frame(height: 150).frame(maxWidth: .infinity)
                    }
                } else {
                    HStack(spacing: 0) {
                        text(tint).frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(tint.line).frame(width: 1)
                        StopArt(stop: stop, tint: tint).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 178)
                }
            }
            .background { tint.background }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.line))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .shadow(color: Color(hue: stop.hue, saturation: 0.7, brightness: 0.3).opacity(hovering ? 0.3 : 0), radius: 18, y: 12)
        .offset(y: hovering ? -3 : 0)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
    }

    private func text(_ tint: CardTint) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: stop.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.tile, in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.25)))
                    .shadow(color: Color(hue: stop.hue, saturation: 0.8, brightness: 0.4).opacity(0.5), radius: 5, y: 3)
                Text(stop.title).font(.system(size: 14, weight: .semibold)).tracking(-0.1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint.ink)
                    .frame(width: 26, height: 26)
                    .background(tint.chip, in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.line))
            }
            Text(stop.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(tint.muted)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Group {
                if done {
                    Label("Done", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Text(stop.time)
                        .foregroundStyle(tint.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tint.chip, in: .capsule)
                        .overlay(Capsule().strokeBorder(tint.line))
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 16))
    }
}

// MARK: - Illustrations

/// Each stop's little looping scene, drawn in code so it stays crisp at any size.
struct StopArt: View {
    let stop: WelcomeStop
    let tint: CardTint
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Group {
                switch stop {
                case .spaces: SpacesArt(t: t)
                case .newTab: KeysArt(t: t, letter: "T", tint: tint, lines: nil)
                case .commands: KeysArt(t: t, letter: "K", tint: tint, lines: ["Split view", "Pin tab", "Ask an agent"])
                case .importing: ImportArt(t: t, tint: tint)
                case .tour: TourArt(t: t, tint: tint)
                case .library: KitsArt(t: t, hue: stop.hue)
                case .agents: AgentsArt(t: t, tint: tint)
                case .makeDefault: MedalArt(t: t, tint: tint)
                }
            }
            .scaleEffect(scale)
        }
        .clipped()
    }
}

private func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

private struct Chip<Content: View>: View {
    let tint: CardTint
    var radius: CGFloat = 9
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(tint.chip, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tint.line))
    }
}

private struct SpacesArt: View {
    let t: Double
    private let spaces: [(String, [Color])] = [
        ("Personal", [Color(red: 0.94, green: 0.42, blue: 0.16), Color(red: 0.72, green: 0.21, blue: 0.05)]),
        ("Work", [Color(red: 0.29, green: 0.49, blue: 0.94), Color(red: 0.14, green: 0.27, blue: 0.69)]),
        ("Side project", [Color(red: 0.21, green: 0.71, blue: 0.43), Color(red: 0.11, green: 0.48, blue: 0.27)]),
    ]

    var body: some View {
        let period = 7.2, seg = period / 3
        let local = t.truncatingRemainder(dividingBy: period)
        let k = floor(local / seg), f = (local - k * seg) / seg
        let pos = k + ease((f - 0.72) / 0.28)
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in panel(spaces[i % 3]) }
            }
            .fixedSize()
            .offset(x: -132 * pos)
            .frame(width: 132, height: 116, alignment: .leading)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            HStack(spacing: 5) {
                Circle().frame(width: 8, height: 8)
                Circle().frame(width: 8, height: 8)
            }
            .foregroundStyle(.secondary)
            .opacity(f > 0.6 && f < 0.95 ? 0.8 : 0)
            .offset(x: f > 0.6 ? 14 - 32 * ease((f - 0.6) / 0.35) : 14)
        }
    }

    private func panel(_ s: (String, [Color])) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 7, height: 7)
                Text(s.0).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.bottom, 3)
            ForEach([1.0, 0.8, 0.66, 0.74], id: \.self) { w in
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.22)).frame(width: 112 * w, height: 15)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 132, height: 116, alignment: .topLeading)
        .background(LinearGradient(colors: s.1, startPoint: .top, endPoint: .bottom))
    }
}

private struct KeysArt: View {
    let t: Double
    let letter: String
    let tint: CardTint
    let lines: [String]?

    var body: some View {
        let period = 2.8, f = t.truncatingRemainder(dividingBy: period) / period
        let pressed = f > 0.4 && f < 0.56
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                cap("⌘", pressed)
                cap(letter, pressed)
            }
            if let lines {
                let lit = Int(t / 1.4) % lines.count
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i])
                            .font(.system(size: 10.5, weight: i == lit ? .semibold : .regular))
                            .foregroundStyle(i == lit ? Color.primary : tint.muted)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(width: 150, alignment: .leading)
                            .background(i == lit ? tint.chip : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                    }
                }
            } else {
                let text = "github.com/jma"
                let n = Int(Double(text.count) * ease((f - 0.48) / 0.32))
                Chip(tint: tint) {
                    HStack(spacing: 1) {
                        Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint.muted).padding(.trailing, 5)
                        Text(String(text.prefix(n))).font(.system(size: 11, design: .monospaced))
                        Rectangle().fill(tint.ink).frame(width: 1.5, height: 12).opacity(Int(t * 2) % 2 == 0 ? 1 : 0)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(width: 170)
                }
            }
        }
    }

    private func cap(_ s: String, _ pressed: Bool) -> some View {
        Text(s)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 40, height: 40)
            .background(tint.chip, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.line))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.08)).frame(height: pressed ? 1 : 3)
            }
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.16), radius: pressed ? 1 : 5, y: pressed ? 0 : 3)
            .offset(y: pressed ? 2 : 0)
    }
}

private struct ImportArt: View {
    let t: Double
    let tint: CardTint

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                ForEach(["C", "S", "A"], id: \.self) { l in
                    Chip(tint: tint) {
                        Text(l).font(.system(size: 12, weight: .bold)).foregroundStyle(tint.ink).frame(width: 30, height: 30)
                    }
                }
            }
            Canvas { ctx, size in
                for k in 0..<5 {
                    let f = (t / 2.4 + Double(k) / 5).truncatingRemainder(dividingBy: 1)
                    let startY = [8.0, 48, 88, 28, 68][k]
                    let x = f * size.width, y = startY + (size.height / 2 - startY) * f
                    let a = f < 0.15 ? f / 0.15 : f > 0.85 ? (1 - f) / 0.15 : 1
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(tint.ink.opacity(a)))
                }
            }
            .frame(width: 46, height: 96)
            Chip(tint: tint, radius: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<6, id: \.self) { k in
                        let f = (t / 4.8 - Double(k) * 0.073).truncatingRemainder(dividingBy: 1)
                        let fill = f < 0.08 ? 0 : f < 0.22 ? ease((f - 0.08) / 0.14) : f < 0.85 ? 1 : 1 - ease((f - 0.85) / 0.15)
                        RoundedRectangle(cornerRadius: 3).fill(tint.ink.opacity(0.35))
                            .frame(width: 96 * [0.9, 0.7, 0.84, 0.6, 0.78, 0.66][k] * max(0, fill), height: 9)
                    }
                }
                .padding(8)
                .frame(width: 112, alignment: .leading)
            }
        }
    }
}

private struct TourArt: View {
    let t: Double
    let tint: CardTint

    var body: some View {
        let lit = Int(t / 1.5) % 4
        ZStack {
            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                GridRow { tile(0, "Split view", lit); tile(1, "Notes", lit) }
                GridRow { tile(2, "Radar", lit); tile(3, "Agents", lit) }
            }
            Image(systemName: "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.tile, in: .circle)
                .shadow(color: Color(hue: tint.hue, saturation: 0.8, brightness: 0.4).opacity(0.6), radius: 8, y: 4)
        }
        .padding(14)
    }

    private func tile(_ i: Int, _ s: String, _ lit: Int) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(i == lit ? Color.primary : tint.muted)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(i == lit ? tint.chip : tint.line.opacity(0.25), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(i == lit ? tint.ink : .clear, lineWidth: 1.5))
            .shadow(color: i == lit ? tint.glow : .clear, radius: 8, y: 4)
            .animation(.easeOut(duration: 0.4), value: lit)
    }
}

private struct KitsArt: View {
    let t: Double
    let hue: Double

    var body: some View {
        ZStack {
            kit(0, "Developer", "JSON, React, Radar", hue, x: -62, angle: -9)
            kit(2, "Writer", "Reader, Clipper", hue + 0.19, x: 62, angle: 9)
            kit(1, "Agents", "MCP, Notes, Space", hue - 0.33, x: 0, angle: 0)
        }
    }

    private func kit(_ i: Int, _ name: String, _ sub: String, _ h: Double, x: CGFloat, angle: Double) -> some View {
        let hh = (h + 1).truncatingRemainder(dividingBy: 1)
        return VStack(alignment: .leading, spacing: 2) {
            Spacer()
            Text(name).font(.system(size: 11, weight: .semibold))
            Text(sub).font(.system(size: 9)).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(9)
        .frame(width: 88, height: 112, alignment: .leading)
        .background(LinearGradient(colors: [Color(hue: hh, saturation: 0.7, brightness: 0.85), Color(hue: hh, saturation: 0.8, brightness: 0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 8)
        .rotationEffect(.degrees(angle))
        .offset(x: x, y: -6 * sin(t * 1.57 + Double(i) * 2.1))
    }
}

private struct AgentsArt: View {
    let t: Double
    let tint: CardTint

    var body: some View {
        let f = t.truncatingRemainder(dividingBy: 5) / 5
        let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 70, y: -46), CGPoint(x: -30, y: -20), CGPoint(x: 0, y: 0)]
        let s = f * 3, i = min(2, Int(s))
        let p = CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * ease(s - Double(i)),
                        y: pts[i].y + (pts[i + 1].y - pts[i].y) * ease(s - Double(i)))
        VStack(spacing: 6) {
            row("Claude Code", live: true)
            row("Codex", live: false)
            row("Cursor", live: false)
        }
        .padding(16)
        .overlay {
            Image(systemName: "cursorarrow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.ink)
                .offset(x: p.x, y: 30 + p.y)
        }
    }

    private func row(_ name: String, live: Bool) -> some View {
        Chip(tint: tint, radius: 8) {
            HStack(spacing: 7) {
                Circle().fill(live ? Color.green : tint.muted.opacity(0.5)).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.green.opacity(live ? 0.5 * (1 - (t.truncatingRemainder(dividingBy: 1.6) / 1.6)) : 0), lineWidth: 4)
                        .scaleEffect(1 + t.truncatingRemainder(dividingBy: 1.6)))
                Text(name).font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text(live ? "Connected" : "Add").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(live ? Color.green : tint.ink)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
        }
    }
}

private struct MedalArt: View {
    let t: Double
    let tint: CardTint

    var body: some View {
        let f = t.truncatingRemainder(dividingBy: 3.6) / 3.6
        let on = ease((f - 0.3) / 0.15) > 0.5
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(red: 0.54, green: 0.23, blue: 0.03), Color(red: 0.96, green: 0.71, blue: 0.27),
                                                       Color(red: 1, green: 0.95, blue: 0.81), Color(red: 0.85, green: 0.54, blue: 0.11),
                                                       Color(red: 0.48, green: 0.17, blue: 0.03), Color(red: 0.94, green: 0.69, blue: 0.25),
                                                       Color(red: 1, green: 0.94, blue: 0.77), Color(red: 0.79, green: 0.45, blue: 0.07),
                                                       Color(red: 0.54, green: 0.23, blue: 0.03)], center: .center))
                    .rotationEffect(.degrees(t * 40))
                Circle().strokeBorder(Color(red: 1, green: 0.94, blue: 0.78).opacity(0.4), lineWidth: 5)
                Text("POWER\nBROWSER").font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.29, green: 0.11, blue: 0.01))
            }
            .frame(width: 88, height: 88)
            .shadow(color: Color(red: 0.55, green: 0.24, blue: 0).opacity(0.5), radius: 12, y: 8)
            Capsule().fill(on ? Color.green : tint.muted.opacity(0.3))
                .frame(width: 44, height: 26)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20).padding(3).shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                }
                .animation(.smooth(duration: 0.3), value: on)
        }
    }
}

// MARK: - The opened card

/// A stop's full card over the page: its scene on the left, the story and its one challenge on
/// the right. Next walks through the stops in order.
private struct StopSheet: View {
    let stop: WelcomeStop
    let progress: WelcomeProgress
    @Binding var open: WelcomeStop?
    let complete: (WelcomeStop) -> Void
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = CardTint(hue: stop.hue, dark: true)
        let done = progress.done.contains(stop)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture { open = nil }
            HStack(spacing: 0) {
                ZStack {
                    tint.background
                    StopArt(stop: stop, tint: tint, scale: 1.25)
                        .environment(\.colorScheme, .dark)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(stop.index + 1) of \(WelcomeStop.allCases.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { open = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Back to all stops")
                    }
                    Text(stop.headline).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(stop.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        Text(stop.challenge).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(stop.time).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 0)
                    HStack {
                        if stop.index > 0 {
                            Button { open = WelcomeStop.allCases[stop.index - 1] } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Previous stop")
                        }
                        Spacer()
                        Button(primaryLabel(done)) { primary(done) }
                            .buttonStyle(.glassProminent)
                            .tint(Color(hue: stop.hue, saturation: 0.75, brightness: 0.8))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(width: 330)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(maxWidth: 820, maxHeight: 420)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.3), radius: 40, y: 24)
            .padding(28)
            .id(stop)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    private func primaryLabel(_ done: Bool) -> String {
        if done { return stop == .makeDefault ? "Finish" : "Next" }
        switch stop {
        case .spaces: return "Try it"
        case .newTab: return "Open the bar"
        case .commands: return "Open commands"
        case .importing: return "Import"
        case .tour: return "Play the tour"
        case .library: return "Open the Library"
        case .agents: return "Add to Claude Code"
        case .makeDefault: return "Make default"
        }
    }

    /// Does the stop's challenge for real where it can; elsewhere, for now, marks it done.
    private func primary(_ done: Bool) {
        if done {
            open = stop == .makeDefault ? nil : WelcomeStop.allCases[stop.index + 1]
            return
        }
        switch stop {
        case .newTab: browser.showCommandBar(.newTab)
        case .commands: browser.showCommandBar(.commands)
        case .makeDefault: WelcomePage.makeDefaultBrowser(); complete(stop)
        default: complete(stop)
        }
    }
}

// MARK: - Arrival

/// Welcome content rising into place, each piece a beat after the last, once the metal starts fading.
private struct WelcomeArrival: ViewModifier {
    let order: Double
    let shown: Bool
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : distance)
            .scaleEffect(shown || Motion.reduced ? 1 : 0.98)
            .animation(shown ? (Motion.reduced ? Motion.spring : .smooth(duration: 1.1)).delay(0.2 + order * 0.11) : nil, value: shown)
    }
}

private extension View {
    func welcomeArrival(_ order: Double, shown: Bool, distance: CGFloat = 16) -> some View {
        modifier(WelcomeArrival(order: order, shown: shown, distance: distance))
    }
}
