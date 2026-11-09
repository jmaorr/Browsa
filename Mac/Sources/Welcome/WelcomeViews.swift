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
        GalleryCard(stop: stop, vertical: vertical, done: progress.done.contains(stop), active: open == nil && shown) { open = stop }
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

private struct GalleryCard: View {
    let stop: WelcomeStop
    let vertical: Bool
    let done: Bool
    /// False while a card is open over the gallery: the heroes behind it stop.
    var active = true
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var played = false
    @State private var visible = false
    /// The hero plays one loop when the card first comes on screen, and while it's hovered,
    /// finishing its loop after the pointer leaves. Otherwise it rests on a still frame.
    @State private var playing = false
    @State private var playStart = Date.now
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        let surface = stop.surface
        let dark = surface.isDark(scheme)
        Button(action: action) {
            Group {
                if vertical {
                    VStack(spacing: 0) {
                        text(dark)
                        hero.frame(height: 210).frame(maxWidth: .infinity)
                    }
                } else {
                    HStack(spacing: 0) {
                        text(dark).frame(width: 250, alignment: .leading)
                        hero.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: 220)
                }
            }
            .background { SurfaceBackground(surface: surface) }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1))
            .environment(\.colorScheme, dark ? .dark : .light)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 20 : 6, y: hovering ? 12 : 3)
        .offset(y: hovering ? -3 : 0)
        .onHover { h in
            withAnimation(Motion.snappy) { hovering = h }
            setPlaying(h && active)
        }
        .onScrollVisibilityChange(threshold: 0.4) { v in
            visible = v
            playFirstLoop()
        }
        .onChange(of: active) { _, on in
            if on { playFirstLoop() } else { stopTask?.cancel(); playing = false }
        }
    }

    /// Once, the first time the card is both on screen and showing (not under the intro or a card).
    private func playFirstLoop() {
        guard visible, active, !played else { return }
        played = true
        setPlaying(true)
        setPlaying(false)
    }

    private func setPlaying(_ want: Bool) {
        stopTask?.cancel()
        if want {
            if !playing { playStart = .now; playing = true }
        } else if playing {
            // Let the loop run to its end, which is the still frame, so stopping never jumps.
            let elapsed = Date.now.timeIntervalSince(playStart)
            let remain = stop.loop - elapsed.truncatingRemainder(dividingBy: stop.loop)
            stopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(remain))
                guard !Task.isCancelled else { return }
                playing = false
            }
        }
    }

    /// The hero keeps the page's own appearance for its UI, so the miniature Browsa matches.
    private var hero: some View {
        // An overlay on a clear view, so the hero's own size never widens the card.
        Color.clear
            .overlay { StopHero(stop: stop, playing: playing, start: playStart).environment(\.colorScheme, scheme) }
            .clipped()
            .allowsHitTesting(false)
    }

    private func text(_ dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: stop.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(LinearGradient(colors: [Color(hue: stop.hue, saturation: 0.62, brightness: 0.95),
                                                         Color(hue: stop.hue, saturation: 0.8, brightness: 0.66)],
                                                startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.25)))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(stop.title).font(.system(size: 14, weight: .semibold)).tracking(-0.1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            }
            Text(stop.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Group {
                if done {
                    Label("Done", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Text(stop.time)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: .capsule)
                }
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 16))
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
        let done = progress.done.contains(stop)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture { open = nil }
            HStack(spacing: 0) {
                ZStack {
                    SurfaceBackground(surface: stop.surface)
                    StopHero(stop: stop, scale: 1.2, playing: true)
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
