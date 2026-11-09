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

    /// The orb's heat colours, red through to yellow, bright enough to read at any width.
    static let heat = LinearGradient(colors: [Color(red: 0.86, green: 0.2, blue: 0.05), Color(red: 0.95, green: 0.42, blue: 0.08),
                                              Color(red: 0.97, green: 0.66, blue: 0.12), Color(red: 0.96, green: 0.82, blue: 0.2)],
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

/// Lets the spike harness put a card in focus without a real pointer.
@MainActor @Observable final class WelcomeDebug {
    static let shared = WelcomeDebug()
    var focus: WelcomeStop?
}

/// The welcome tab's page: a title, the level bar, and the stops as a gallery of cards. Each card
/// is learned in place: hovering it opens it a little and says what to do, doing it ticks the card
/// off and folds it down. During the intro the page waits for the metal to start fading, then rises.
struct WelcomePage: View {
    @Environment(Browser.self) private var browser
    @State private var progress = WelcomeProgress.shared

    private var shown: Bool { browser.intro == nil || browser.intro == .cards }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            ScrollView {
                VStack(spacing: 30) {
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
                        .frame(maxWidth: 620)
                        .welcomeArrival(1, shown: shown)
                    gallery
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 40)
                .padding(.top, 56)
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .onChange(of: browser.commandBar) { _, mode in
            if mode == .newTab { complete(.newTab) }
            if mode == .commands { complete(.commands) }
        }
    }

    private var gallery: some View {
        VStack(spacing: 20) {
            card(.spaces, 2)
            HStack(alignment: .top, spacing: 20) {
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
        GalleryCard(stop: stop, vertical: vertical, done: progress.done.contains(stop), active: shown) { complete(stop) }
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

/// One segment per stop, with the levels as badges on the bar and their names beneath. The fill
/// is one gradient across the whole bar, showing through the segments that are done.
private struct LevelBar: View {
    let done: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let current = WelcomeLevel.level(for: done)
        ZStack {
            row { _ in
                Capsule().fill(.quaternary.opacity(0.6)).overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
            } badge: { level in
                Badge(level: level, reached: done >= level.threshold, current: level == current, glow: scheme == .dark)
            }
            WelcomePalette.heat
                .mask {
                    row { i in
                        Capsule().scaleEffect(x: i < done ? 1 : 0, anchor: .leading)
                            .animation(.smooth(duration: 0.8), value: i < done)
                    } badge: { _ in Color.clear }
                }
                .allowsHitTesting(false)
        }
        .frame(height: 24)
        .padding(.bottom, 22)
    }

    /// The bar's layout, shared by the track and the fill's mask so they line up exactly.
    private func row<S: View, B: View>(@ViewBuilder segment: @escaping (Int) -> S, @ViewBuilder badge: @escaping (WelcomeLevel) -> B) -> some View {
        HStack(spacing: 4) {
            ForEach(WelcomeLevel.allCases, id: \.self) { level in
                if level != .rookie {
                    ForEach(WelcomeLevel(rawValue: level.rawValue - 1)!.threshold..<level.threshold, id: \.self) { i in
                        segment(i).frame(height: 7)
                    }
                }
                badge(level).frame(width: 24, height: 24)
            }
        }
    }

    private struct Badge: View {
        let level: WelcomeLevel
        let reached: Bool
        let current: Bool
        /// The warm glow under reached badges: lovely on dark, muddy on light.
        let glow: Bool

        var body: some View {
            ZStack {
                Circle().fill(reached ? AnyShapeStyle(WelcomePalette.metal) : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
                Circle().strokeBorder(reached ? Color(red: 1, green: 0.94, blue: 0.78).opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1.5)
                Image(systemName: level.symbol)
                    .font(.system(size: level == .rookie ? 6 : 10, weight: .bold))
                    .foregroundStyle(reached ? Color.white : Color.secondary)
            }
            .frame(width: 24, height: 24)
            .shadow(color: reached && glow ? Color(red: 0.78, green: 0.16, blue: 0.04).opacity(0.45) : .clear, radius: 6, y: 3)
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

extension WelcomeStop {
    /// What to do, shown when the card opens up.
    var instruction: String {
        switch self {
        case .spaces: "Swipe sideways with two fingers on this card"
        case .newTab: "Press ⌘T now"
        case .commands: "Press ⌘K now"
        case .importing: "Pick the browser you're coming from"
        case .tour: "Keep the pointer here to watch"
        case .library: "Add a kit to set Browsa up"
        case .agents: "Add Browsa to your agent"
        case .makeDefault: "Make Browsa the browser links open in"
        }
    }

    var instructionSymbol: String {
        switch self {
        case .spaces: "hand.draw"
        case .newTab, .commands: "keyboard"
        case .importing: "square.and.arrow.down"
        case .tour: "eye"
        case .library: "square.grid.2x2"
        case .agents: "terminal"
        case .makeDefault: "star"
        }
    }
}

/// A stop as a card that's learned in place. At rest it shows its story and a still of its hero.
/// Hover opens it a little and says what to do; doing it plays the hero through, ticks the card
/// and folds it down to a slim done row. Clicking keeps it open without a hover.
private struct GalleryCard: View {
    let stop: WelcomeStop
    let vertical: Bool
    let done: Bool
    /// False until the page has risen out of the intro.
    var active = true
    let complete: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var debug = WelcomeDebug.shared

    @State private var hovering = false
    @State private var pinned = false
    /// After ticking off, the card folds down even while still hovered, until the pointer leaves.
    @State private var folded = false
    @State private var celebrating = false
    @State private var unhover: Task<Void, Never>?

    @State private var played = false
    @State private var visible = false
    @State private var playing = false
    @State private var playStart = Date.now
    @State private var stopTask: Task<Void, Never>?
    @State private var watchTask: Task<Void, Never>?

    // Spaces
    @State private var spacePos = 0.0
    @State private var swipeMonitor: Any?
    @State private var swipeTravel = 0.0
    @State private var swipeLatched = false

    // Import
    @State private var importFrom: String?
    @State private var importing = false

    private var focused: Bool { active && !folded && (hovering || pinned || debug.focus == stop) }
    private var compact: Bool { done && !celebrating && !focused }
    private var expanded: Bool { focused && !compact }

    private var expandedHeight: CGFloat {
        switch stop {
        case .importing, .agents, .library: 300
        case .tour: 330
        default: 286
        }
    }

    var body: some View {
        let surface = stop.surface
        let dark = surface.isDark(scheme)
        Group {
            if compact {
                doneRow
            } else if vertical {
                VStack(spacing: 0) {
                    text(dark)
                    hero.frame(height: 210).frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    text(dark).frame(width: 300, alignment: .leading)
                    hero.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: expanded ? expandedHeight : 220)
            }
        }
        .background { if !compact { SurfaceBackground(surface: surface) } else { compactBackground } }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(compact ? Color.primary.opacity(0.08) : dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, compact ? scheme : dark ? .dark : .light)
        .contentShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(expanded ? 0.16 : compact ? 0 : 0.06), radius: expanded ? 22 : 6, y: expanded ? 12 : 3)
        .animation(.smooth(duration: 0.45), value: expanded)
        .animation(.smooth(duration: 0.5), value: compact)
        .onTapGesture { pinned.toggle() }
        .onHover(perform: hover)
        .onScrollVisibilityChange(threshold: 0.4) { v in
            visible = v
            playFirstLoop()
        }
        .onChange(of: active) { _, on in if on { playFirstLoop() } }
        .onChange(of: focused) { _, on in focusChanged(on) }
        .onChange(of: done) { _, now in if now { celebrate() } }
        .onDisappear { endSwipes() }
    }

    // MARK: Focus

    private func hover(_ h: Bool) {
        unhover?.cancel()
        if h {
            hovering = true
        } else {
            // A short grace, so the card growing under the pointer never flickers it closed.
            unhover = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                hovering = false
                pinned = false
                folded = false
            }
        }
    }

    private func focusChanged(_ on: Bool) {
        setPlaying(on && stop != .spaces)
        if on, !done {
            if stop == .spaces { beginSwipes() }
            if stop == .tour { watchTour() }
        } else {
            endSwipes()
            watchTask?.cancel()
        }
    }

    /// Ticked off: let the hero finish its moment, then fold the card down.
    private func celebrate() {
        celebrating = true
        endSwipes()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            celebrating = false
            pinned = false
            if hovering { folded = true }
        }
    }

    // MARK: Spaces: a real two-finger swipe on the card

    private func beginSwipes() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only sideways swipes; vertical scrolling still moves the page.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 || swipeTravel != 0 else { return event }
            if event.phase == .began { swipeTravel = 0; swipeLatched = false }
            swipeTravel += event.scrollingDeltaX
            if !swipeLatched, abs(swipeTravel) > 70 {
                swipeLatched = true
                withAnimation(.smooth(duration: 0.6)) { spacePos += 1 }
                if spacePos >= 2 { complete() }
            }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                swipeTravel = 0
                swipeLatched = false
            }
            return nil
        }
    }

    private func endSwipes() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        swipeTravel = 0
    }

    // MARK: Tour: watching it through counts

    private func watchTour() {
        watchTask?.cancel()
        watchTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(stop.loop))
            guard !Task.isCancelled, focused else { return }
            complete()
        }
    }

    // MARK: Hero playback

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
            .overlay {
                StopHero(stop: stop, playing: playing || (stop == .importing && importing), start: playStart,
                         spacePos: stop == .spaces && focused ? spacePos : nil)
                    .environment(\.colorScheme, scheme)
            }
            .overlay(alignment: .topTrailing) {
                if celebrating {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        .padding(16)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(.bouncy(duration: 0.45, extraBounce: 0.2), value: celebrating)
            .clipped()
            .allowsHitTesting(false)
    }

    // MARK: Text column

    private var tile: some View {
        Image(systemName: stop.symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(LinearGradient(colors: [Color(hue: stop.hue, saturation: 0.62, brightness: 0.95),
                                                 Color(hue: stop.hue, saturation: 0.8, brightness: 0.66)],
                                        startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private func text(_ dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                tile
                Text(stop.title).font(.system(size: 14, weight: .semibold)).tracking(-0.1)
                Spacer(minLength: 6)
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.green)
                } else {
                    Text(stop.time)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: .capsule)
                }
            }
            Text(stop.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if expanded {
                action
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .foregroundStyle(.primary)
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 18))
    }

    /// What to do: the instruction, and for the stops done in the card, its controls.
    @ViewBuilder private var action: some View {
        VStack(alignment: .leading, spacing: 10) {
            if done {
                Label("Done", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
            } else {
                instruction
                controls
            }
        }
    }

    private var instruction: some View {
        HStack(spacing: 8) {
            Image(systemName: stop.instructionSymbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: expanded)
            if stop == .newTab || stop == .commands {
                Text("Press").font(.system(size: 12.5, weight: .medium))
                KeyCap(text: "⌘")
                KeyCap(text: stop == .newTab ? "T" : "K")
                Text("now").font(.system(size: 12.5, weight: .medium))
            } else {
                Text(stop.instruction).font(.system(size: 12.5, weight: .medium))
            }
            if stop == .spaces {
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Double(i) <= spacePos ? Color.primary : Color.primary.opacity(0.2)).frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }

    @ViewBuilder private var controls: some View {
        switch stop {
        case .importing:
            if importing {
                ProgressView().controlSize(.small).progressViewStyle(.linear)
                Text("Bringing over bookmarks, history and passwords…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(["Chrome", "Safari", "Arc", "Firefox"], id: \.self) { b in
                        Button(b) { importFrom = b }
                            .buttonStyle(.glass)
                            .tint(importFrom == b ? .accentColor : nil)
                            .controlSize(.small)
                    }
                }
                if let from = importFrom {
                    Button("Import from \(from)") { runImport() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
            }
        case .library:
            HStack(spacing: 8) {
                Button("Add Developer kit") { complete() }.buttonStyle(.glassProminent).controlSize(.small)
                Button("Browse the Library") {}.buttonStyle(.glass).controlSize(.small)
            }
        case .agents:
            HStack(spacing: 6) {
                ForEach(["Claude Code", "Codex", "Cursor"], id: \.self) { a in
                    Button(a) { complete() }.buttonStyle(.glass).controlSize(.small)
                }
            }
        case .makeDefault:
            Button("Make Browsa my default") {
                WelcomePage.makeDefaultBrowser()
                complete()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        case .tour:
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                let f = min(1, context.date.timeIntervalSince(playStart) / stop.loop)
                Capsule().fill(.primary.opacity(0.12)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Color.primary.opacity(0.8)).frame(width: g.size.width * f) }
                    }
            }
            .frame(height: 4)
        default:
            EmptyView()
        }
    }

    private func runImport() {
        importing = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(stop.loop * 0.75))
            importing = false
            complete()
        }
    }

    // MARK: Done

    private var compactBackground: some View {
        Color(nsColor: .textBackgroundColor)
    }

    private var doneRow: some View {
        HStack(spacing: 12) {
            tile.scaleEffect(0.85)
            Text(stop.title).font(.system(size: 13.5, weight: .semibold))
            Spacer()
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }
}

/// A small keycap for instructions, like the shortcut hints in menus.
private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .frame(minWidth: 20, minHeight: 20)
            .background(.background.opacity(0.9), in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
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
