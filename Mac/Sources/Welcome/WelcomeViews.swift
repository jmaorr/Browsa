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
                    .foregroundStyle(.white)
                    // A warm shadow keeps white legible over the metal's bright bands in either mode.
                    .shadow(color: Color(red: 0.42, green: 0.08, blue: 0).opacity(0.45), radius: 16, y: 2)
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
        case .spaces: "A place to keep your tabs organised for Work, Personal, and anything else."
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

    /// Bumped on reset, so the cards' own state starts over too.
    private(set) var generation = 0

    func reset() {
        generation += 1
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

/// The shortcuts the welcome page catches while onboarding is under way, handed to the cards so
/// they play on the card's own UI instead of switching spaces or opening a tab.
@MainActor @Observable final class WelcomeInput {
    static let shared = WelcomeInput()
    enum Event { case space(Int), spaceStep(Int), shortcut(CommandBarMode) }
    private(set) var last: (event: Event, id: UUID)?
    func send(_ event: Event) { last = (event, UUID()) }
}

/// The welcome tab's page: a title near the middle of the first screen, the level bar and the
/// stops below it. Each card teaches its stop in place and ticks itself off when you do it.
/// During the intro the page waits for the metal to start fading, then rises.
struct WelcomePage: View {
    @Environment(Browser.self) private var browser
    @State private var progress = WelcomeProgress.shared
    @State private var keyMonitor: Any?

    /// Until every stop is done, the page keeps the shortcuts it teaches to itself.
    private var onboarding: Bool { progress.done.count < WelcomeStop.allCases.count }
    private var shown: Bool { browser.intro == nil || browser.intro == .cards }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 30) {
                    // The title sits a little above the middle of the first screen; the stops
                    // start just below the fold, with the bar and the first card peeking up.
                    VStack(spacing: 6) {
                        Text("Make Browsa yours")
                            .font(.system(size: 34, weight: .semibold))
                            .tracking(-0.8)
                        Text("Eight short stops, about four minutes. Skip any of them.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: max(220, viewport.size.height * 0.56), alignment: .bottom)
                    .welcomeArrival(0, shown: shown)
                    LevelBar(done: progress.done.count)
                        .frame(maxWidth: 620)
                        .padding(.bottom, 24)
                        .welcomeArrival(1, shown: shown)
                    gallery
                        .id(progress.generation)
                    Button("Reset Progress", systemImage: "arrow.counterclockwise") {
                        progress.reset()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.top, 20)
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 40)
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: browser.commandBar) { _, mode in
            if mode == .newTab { complete(.newTab) }
            if mode == .commands { complete(.commands) }
        }
        .onAppear(perform: catchShortcuts)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// While onboarding, ⌃1–9, ⌥⌘← →, ⌘T and ⌘K play on the cards instead of leaving the page,
    /// so people can try them freely. Once every stop is done they go back to normal.
    private func catchShortcuts() {
        guard keyMonitor == nil else { return }
        let input = WelcomeInput.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard onboarding, browser.commandBar == nil, event.window === browser.nsWindow else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if mods == .control, let n = Int(key), (1...9).contains(n) {
                if n <= 3 { input.send(.space(n - 1)) }
                return nil
            }
            if mods == [.command, .option], event.keyCode == 123 || event.keyCode == 124 {
                input.send(.spaceStep(event.keyCode == 124 ? 1 : -1))
                return nil
            }
            if mods == .command, key == "t" || key == "k" {
                let mode: CommandBarMode = key == "t" ? .newTab : .commands
                input.send(.shortcut(mode))
                complete(mode == .newTab ? .newTab : .commands)
                return nil
            }
            return event
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

/// A stop as a fixed card. It shows its story, a hero of the real UI, and (as each stop gets its
/// pass) a small instruction card saying what to do. Doing it for real ticks the card: its icon
/// turns green with a flourish. The hero rests on a still frame and plays on first view and hover.
private struct GalleryCard: View {
    let stop: WelcomeStop
    let vertical: Bool
    let done: Bool
    /// False until the page has risen out of the intro.
    var active = true
    let complete: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var debug = WelcomeDebug.shared
    @State private var input = WelcomeInput.shared

    @State private var hovering = false
    @State private var played = false
    @State private var visible = false
    @State private var playing = false
    @State private var playStart = Date.now
    @State private var stopTask: Task<Void, Never>?

    // Spaces: the person drives the hero by swiping on the card or with ⌃1–3 / ⌥⌘← →.
    @State private var spacePos = 0.0
    @State private var visited: Set<Int> = [0]
    @State private var monitors: [Any] = []
    @State private var swipeTravel = 0.0
    @State private var swipeLatched = false

    private var height: CGFloat { stop == .spaces ? 320 : 220 }

    var body: some View {
        let surface = stop.surface
        let dark = surface.isDark(scheme)
        Group {
            if vertical {
                VStack(spacing: 0) {
                    text
                    hero.frame(height: 210).frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    text.frame(width: 330, alignment: .leading)
                    hero.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: height)
            }
        }
        .background { SurfaceBackground(surface: surface) }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
        .contentShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
        .animation(.smooth(duration: 0.3), value: hovering)
        .onHover { h in
            hovering = h
            if stop != .spaces { setPlaying(h && active) }
        }
        .onScrollVisibilityChange(threshold: 0.4) { v in
            visible = v
            playFirstLoop()
        }
        .onChange(of: active) { _, on in if on { playFirstLoop() } }
        .onAppear { if stop == .spaces { listen() } }
        .onDisappear { stopListening() }
        .onChange(of: input.last?.id) { if let e = input.last?.event { handle(e) } }
    }

    // MARK: Spaces: real gestures and shortcuts drive the hero

    /// The page's caught shortcuts, played on this card. Still works after the card is done.
    private func handle(_ event: WelcomeInput.Event) {
        switch (stop, event) {
        case (.spaces, .space(let i)): go(to: i)
        case (.spaces, .spaceStep(let d)): step(d)
        case (.newTab, .shortcut(.newTab)), (.commands, .shortcut(.commands)): pressPlay()
        default: break
        }
    }

    /// Plays the shortcut hero from the key press, once.
    private func pressPlay() {
        stopTask?.cancel()
        playStart = .now.addingTimeInterval(-0.1 * stop.loop)
        playing = true
        setPlaying(false)
    }

    /// Two-finger sideways swipes over the Spaces card play on its own window, during onboarding and after.
    private func listen() {
        guard monitors.isEmpty else { return }
        if let swipe = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            // Sideways two-finger swipes over this card only; vertical scrolling still moves the page.
            guard hovering || debug.focus == stop,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 || swipeTravel != 0 else { return event }
            if event.phase == .began { swipeTravel = 0; swipeLatched = false }
            swipeTravel += event.scrollingDeltaX
            if !swipeLatched, abs(swipeTravel) > 60 {
                swipeLatched = true
                // Natural direction: fingers moving left bring in the next space.
                step(swipeTravel < 0 ? 1 : -1)
            }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                swipeTravel = 0
                swipeLatched = false
            }
            return nil
        }) { monitors.append(swipe) }
    }

    private func stopListening() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        swipeTravel = 0
    }

    private var currentSpace: Int { ((Int(spacePos.rounded()) % 3) + 3) % 3 }

    private func step(_ delta: Int) {
        withAnimation(.smooth(duration: 0.55)) { spacePos = spacePos.rounded() + Double(delta) }
        arrived()
    }

    private func go(to index: Int) {
        var delta = index - currentSpace
        if delta > 1 { delta -= 3 }
        if delta < -1 { delta += 3 }
        guard delta != 0 else { return }
        withAnimation(.smooth(duration: 0.55)) { spacePos = spacePos.rounded() + Double(delta) }
        arrived()
    }

    private func arrived() {
        visited.insert(currentSpace)
        if visited.count == 3, !done {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                complete()
            }
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
                StopHero(stop: stop, playing: playing && stop != .spaces, start: playStart, spacePos: stop == .spaces ? spacePos : nil)
                    .environment(\.colorScheme, scheme)
            }
            .clipped()
            .allowsHitTesting(false)
    }

    // MARK: Text column

    private var text: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DoneTile(stop: stop, done: done)
                Text(stop.title).font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                Spacer(minLength: 6)
                if !done {
                    Text(stop.time)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: .capsule)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: done)
            Text(stop.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if stop == .spaces {
                SpacesInstruction(done: done)
            }
        }
        .foregroundStyle(.primary)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 20))
    }
}

/// The stop's icon tile. Done, it turns green with a check, a ring that rings out and a few sparks.
private struct DoneTile: View {
    let stop: WelcomeStop
    let done: Bool
    @State private var burst = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: done
                                     ? [Color(red: 0.36, green: 0.84, blue: 0.44), Color(red: 0.13, green: 0.62, blue: 0.27)]
                                     : [Color(hue: stop.hue, saturation: 0.62, brightness: 0.95), Color(hue: stop.hue, saturation: 0.8, brightness: 0.66)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25))
            Image(systemName: done ? "checkmark" : stop.symbol)
                .font(.system(size: done ? 15 : 14, weight: done ? .bold : .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .frame(width: 34, height: 34)
        .shadow(color: (done ? Color.green : .black).opacity(done ? 0.35 : 0.2), radius: done ? 8 : 4, y: 2)
        .scaleEffect(burst ? 1.18 : 1)
        .background {
            // The flourish: a ring ringing out and sparks flying off, once.
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.green.opacity(burst ? 0 : 0.7), lineWidth: 2)
                    .scaleEffect(burst ? 2.1 : 1)
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(i.isMultiple(of: 2) ? Color.green : Color.yellow)
                        .frame(width: 4, height: 4)
                        .offset(y: burst ? -34 : -12)
                        .rotationEffect(.degrees(Double(i) * 45))
                        .opacity(burst ? 0 : 1)
                }
            }
            .opacity(done ? 1 : 0)
        }
        .animation(.smooth(duration: 0.4), value: done)
        .onChange(of: done) { _, now in
            guard now else { return }
            burst = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { burst = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.smooth(duration: 0.4)) { burst = false }
            }
        }
    }
}

/// The instruction for Spaces: a small, clean card that says what to try, with the keyboard way
/// for people with a mouse, and a trackpad showing the swipe.
private struct SpacesInstruction: View {
    let done: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TryBadge(done: done)
            card
        }
        .environment(\.colorScheme, .light)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Swipe to switch spaces")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize()
                HStack(spacing: 4) {
                    Text("or press").foregroundStyle(.secondary)
                    KeyCap(text: "⌃1")
                    KeyCap(text: "⌃2")
                    KeyCap(text: "⌃3")
                }
                .font(.system(size: 11.5))
                .fixedSize()
            }
            Spacer(minLength: 0)
            Trackpad()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.95), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.06)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }
}

/// "Try it", or "Done" once learned: a small white pill above the instruction card.
private struct TryBadge: View {
    let done: Bool
    var body: some View {
        Label(done ? "Done" : "Try it", systemImage: done ? "checkmark" : "hand.tap.fill")
            .font(.system(size: 10.5, weight: .bold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(done ? Color(red: 0.12, green: 0.55, blue: 0.24) : Color(white: 0.15))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.white.opacity(0.95), in: .capsule)
            .overlay(Capsule().strokeBorder(.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.3), value: done)
    }
}

/// A trackpad with two fingertips sliding sideways, on a loop.
private struct Trackpad: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.reduced)) { context in
            let f = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            let x = 14 - 28 * welcomeEase((f - 0.15) / 0.55)
            let a = f < 0.1 ? f / 0.1 : f > 0.75 ? max(0, 1 - (f - 0.75) / 0.15) : 1
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.89)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.1)))
                .overlay {
                    HStack(spacing: 4) {
                        Circle().frame(width: 7, height: 7)
                        Circle().frame(width: 7, height: 7)
                    }
                    .foregroundStyle(Color(white: 0.35))
                    .offset(x: x)
                    .opacity(a)
                }
                .frame(width: 58, height: 42)
        }
    }
}

/// A small keycap for instructions, like the shortcut hints in menus.
private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 18)
            .background(.white, in: .rect(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.14)))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
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
