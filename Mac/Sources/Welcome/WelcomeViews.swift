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
        case .commands: "⌘K launches plugins"
        case .importing: "Bring your stuff"
        case .tour: "See it in action"
        case .library: "Unlock more with Library"
        case .agents: "Let your agents in"
        case .makeDefault: "Make it yours"
        }
    }

    var detail: String {
        switch self {
        case .spaces: "A place to keep your tabs organised for Work, Personal, and anything else."
        case .newTab: "Search, type an address, or jump to a tab you already have open."
        case .commands: "Launch powerful plugins like Radar, Comments and more, without leaving the keyboard."
        case .importing: "Bring over your bookmarks and history, and from Arc, your spaces and tabs. Your old browser stays as it is."
        case .tour: "Browsa's film: Spaces, notes on any page, and your agents at work. Sound on."
        case .library: "Powerful plugins, extensions and MCPs built for the hustle."
        case .agents: "Browsa runs an MCP server on your Mac, so your agents can open tabs, read pages and leave notes."
        case .makeDefault: "Links from Mail, Slack and everywhere else will open here."
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
        case .library: "Unlock more with Library"
        case .agents: "Your agents can browse too"
        case .makeDefault: "Make Browsa your browser"
        }
    }

    var challenge: String {
        switch self {
        case .spaces: "Swipe to another space"
        case .newTab: "Press ⌘T"
        case .commands: "Press ⌘K"
        case .importing: "Import from another browser"
        case .tour: "Watch the film"
        case .library: "Turn on the Agent Pack"
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
        _ = withAnimation(.smooth(duration: 0.8)) { done.insert(stop) }
        UserDefaults.standard.set(done.map(\.rawValue), forKey: Self.key)
        return level != before ? level : nil
    }

    /// Bumped on reset, so the cards' own state starts over too.
    private(set) var generation = 0

    func reset() {
        generation += 1
        WelcomeImport.shared.reset()
        done = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: - The page

/// Lets the spike harness put a card in focus without a real pointer.
@MainActor @Observable final class WelcomeDebug {
    static let shared = WelcomeDebug()
    var focus: WelcomeStop?
    /// A card's main action, as if clicked (with its pick, if any).
    var act: (stop: WelcomeStop, choice: String?, id: UUID)?
}

/// A completion pulse to play across the page, from a point in the page's coordinates.
@MainActor @Observable final class WelcomePulse {
    static let shared = WelcomePulse()
    private(set) var stop: WelcomeStop?
    private(set) var started = Date.distantPast
    func fire(from stop: WelcomeStop) { self.stop = stop; started = .now }
    func end(_ start: Date) { if started == start { stop = nil } }
}

/// Where each card's icon tile sits, so the page can start a pulse from it exactly.
struct WelcomeTileAnchors: PreferenceKey {
    static let defaultValue: [WelcomeStop: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [WelcomeStop: Anchor<CGPoint>], nextValue: () -> [WelcomeStop: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
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
    /// The pinned header's height, so the cards can fade out where they pass under it.
    @State private var headerHeight: CGFloat = 200

    /// Until every stop is done, the page keeps the shortcuts it teaches to itself.
    private var onboarding: Bool { progress.done.count < WelcomeStop.allCases.count }
    private var shown: Bool { browser.intro == nil || browser.intro == .cards }

    var body: some View {
        GeometryReader { viewport in
            // The icon sits a little above the middle of the first screen and scrolls away; the
            // title and the level bar pin to the top, with the cards fading out under them.
            let heroHeight = max(300, viewport.size.height * 0.44)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                        .padding(.bottom, 4)
                        .frame(height: heroHeight - 90, alignment: .bottom)
                        .welcomeArrival(0, shown: shown)
                    Section {
                        VStack(spacing: 20) {
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
                        .padding(.top, 28)
                        .padding(.bottom, 64)
                        .frame(maxWidth: .infinity)
                        .mask { fadeUnderHeader }
                    } header: {
                        header
                    }
                }
            }
            .scrollIndicators(.automatic)
            .backgroundPreferenceValue(WelcomeTileAnchors.self) { anchors in
                GeometryReader { g in PulseLayer(anchors: anchors, proxy: g) }
            }
        }
        .coordinateSpace(.named(WelcomePage.space))
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

    /// While onboarding, ⌃1–9, the space keys (⌥⌘← →), ⌘T and ⌘K play on the cards instead of leaving the page,
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
            let keys = Shortcuts.shared
            if keys.matches(.nextSpace, event) || keys.matches(.previousSpace, event) {
                input.send(.spaceStep(keys.matches(.nextSpace, event) ? 1 : -1))
                return nil
            }
            if keys.matches(.newTab, event) || keys.matches(.commands, event) {
                let mode: CommandBarMode = keys.matches(.newTab, event) ? .newTab : .commands
                input.send(.shortcut(mode))
                complete(mode == .newTab ? .newTab : .commands)
                return nil
            }
            return event
        }
    }

    static let space = "welcomePage"

    /// Hides the cards behind the pinned header, with a soft 56pt fade where they meet it.
    private var fadeUnderHeader: some View {
        GeometryReader { g in
            let cutoff = headerHeight - g.frame(in: .scrollView).minY
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 56)
                Color.black.frame(height: g.size.height + 56)
            }
            .offset(y: cutoff)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .clipped()
        }
    }

    /// The title, its line and the level bar. Pinned, it floats over the page's own shader while the
    /// cards dissolve as they pass under it (see `fadeUnderHeader`).
    private var header: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("Make Browsa yours")
                    .font(.system(size: 46, weight: .bold))
                    .tracking(-1.4)
                Text("Get the most out of Browsa in a few minutes")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .welcomeArrival(0, shown: shown)
            LevelBar(done: progress.done.count)
                .frame(maxWidth: 620)
                .padding(.top, 30)
                .welcomeArrival(1, shown: shown)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: 780)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        .zIndex(1)
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
            DefaultCard(done: progress.done.contains(.makeDefault)) { complete(.makeDefault) }
                .welcomeArrival(8, shown: shown, distance: 22)
        }
    }

    private func card(_ stop: WelcomeStop, _ order: Double, vertical: Bool = false) -> some View {
        GalleryCard(stop: stop, vertical: vertical, done: progress.done.contains(stop), active: shown) { complete(stop) }
            .welcomeArrival(order, shown: shown, distance: 22)
    }

    private func complete(_ stop: WelcomeStop) {
        if let level = progress.complete(stop) { browser.showToast("New level · \(level.name)") }
    }

    /// Asks macOS to make Browsa the default browser. macOS confirms with the person first;
    /// `done` runs on the main actor only if they said yes.
    static func makeDefaultBrowser(done: @escaping @MainActor () -> Void = {}) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else { return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                Task { @MainActor in done() }
            }
        }
    }

    /// Whether Browsa already opens web links.
    static var isDefaultBrowser: Bool {
        guard let url = URL(string: "https://browsa.app"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
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
            let prefix = current ? Text("Level \(level.rawValue + 1) · ").foregroundStyle(.secondary).fontWeight(.regular) : Text("")
            let name = Text(level.name).foregroundStyle(reached ? .primary : .secondary)
            return Text("\(prefix)\(name)")
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
    @Environment(Browser.self) private var browser
    @State private var debug = WelcomeDebug.shared
    @State private var input = WelcomeInput.shared

    @State private var hovering = false
    @State private var playing = false
    @State private var playStart = Date.now
    @State private var playTasks: [Task<Void, Never>] = []
    /// The browser, kit or agent picked in the instruction card.
    @State private var choice: String?
    @State private var importer = WelcomeImport.shared
    @State private var importStart = Date.now

    // Spaces: the person drives the hero by swiping on the card or with ⌃1–3 / ⌥⌘← →.
    @State private var spacePos = 0.0
    @State private var visited: Set<Int> = [0]
    @State private var monitors: [Any] = []
    @State private var swipeTravel = 0.0
    @State private var swipeLatched = false

    private var height: CGFloat { stop == .spaces ? 320 : 300 }

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
        .onHover { hovering = $0 }
        .onChange(of: importer.phase) { _, phase in
            guard stop == .importing else { return }
            if phase == .importing { importStart = .now }
            if case .done = phase { complete() }
        }
        .onChange(of: debug.act?.id) {
            guard let a = debug.act, a.stop == stop else { return }
            if let c = a.choice { choice = c }
            act()
        }
        .onAppear { if stop == .spaces { listen() } }
        .onDisappear { stopListening() }
        .onChange(of: input.last?.id) { if let e = input.last?.event { handle(e) } }
        .onChange(of: done) { _, now in if now { WelcomePulse.shared.fire(from: stop) } }
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
    private func pressPlay() { play(from: 0.1 * stop.loop) }

    /// Two-finger sideways swipes over the Spaces card play on its own window, during onboarding and after.
    private func listen() {
        guard monitors.isEmpty else { return }
        if let swipe = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            // Each new gesture starts fresh, whichever way it begins.
            if event.phase == .began { swipeTravel = 0; swipeLatched = false }
            // Sideways two-finger swipes over this card only; vertical scrolling still moves the page.
            guard hovering || debug.focus == stop,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 || swipeTravel != 0 else { return event }
            // One space per gesture: the momentum after a quick flick never moves another.
            if event.momentumPhase != [] { return nil }
            swipeTravel += event.scrollingDeltaX
            if !swipeLatched, abs(swipeTravel) > 60 {
                swipeLatched = true
                // Natural direction: fingers moving left bring in the next space.
                step(swipeTravel < 0 ? 1 : -1)
            }
            if event.phase == .ended || event.phase == .cancelled {
                swipeTravel = 0
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
        if visited.count >= 2, !done {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                complete()
            }
        }
    }

    // MARK: Acting

    /// Plays the hero once, from `offset` seconds in. It only ever plays because the person did something.
    private func play(from offset: Double = 0, completeAt fraction: Double? = nil) {
        playTasks.forEach { $0.cancel() }
        playStart = .now.addingTimeInterval(-offset)
        playing = true
        let length = stop.loop - offset
        var tasks: [Task<Void, Never>] = []
        if let fraction {
            tasks.append(Task { @MainActor in
                try? await Task.sleep(for: .seconds(stop.loop * fraction - offset))
                guard !Task.isCancelled else { return }
                complete()
            })
        }
        tasks.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled else { return }
            playing = false
        })
        playTasks = tasks
    }

    private func stopPlaying() {
        playTasks.forEach { $0.cancel() }
        playing = false
    }

    /// The card's main action: import, play the tour, add the kit, connect the agent, make default.
    private func act() {
        switch stop {
        case .importing:
            if let name = choice, let s = importer.sources.first(where: { $0.name == name }) { importer.pick(s) }
            Task { await importer.run(into: browser.library) }
        case .tour: WelcomeFilm.shared.toggle(finished: complete)
        case .library: break
        case .agents: break
        case .makeDefault: play(completeAt: 0.5)
        case .newTab, .commands: pressPlay()
        case .spaces: break
        }
    }

    /// The hero keeps the page's own appearance for its UI, so the miniature Browsa matches.
    private var hero: some View {
        // An overlay on a clear view, so the hero's own size never widens the card.
        Color.clear
            .overlay {
                if stop == .importing {
                    // The importer itself sits in the card's right side.
                    ImportPanel().environment(\.colorScheme, scheme)
                } else if stop == .tour {
                    // The film itself, playing in the card.
                    FilmPanel(complete: complete)
                } else if stop == .library {
                    // The Agent Pack, for real: one switch turns on Radar, Notes and Agents.
                    AgentPackPanel(done: done, complete: complete).environment(\.colorScheme, scheme)
                } else if stop == .agents {
                    // So does the real agent connector, on the card's dark surface.
                    AgentConnectPanel(done: done, complete: complete).environment(\.colorScheme, .dark)
                } else {
                    StopHero(stop: stop, playing: playing && stop != .spaces, start: playStart,
                             spacePos: stop == .spaces ? spacePos : nil,
                             rest: done ? stop.doneRest : stop.rest, choice: choice)
                        .environment(\.colorScheme, scheme)
                }
            }
            .clipped()
            .contentShape(.rect)
            // Make default: the settings menu in the hero is the control itself.
            .gesture(TapGesture().onEnded {
                guard !playing else { return }
                WelcomePage.makeDefaultBrowser()
                act()
            }, isEnabled: stop == .makeDefault && !done)
            .pointerStyle(stop == .makeDefault && !done ? .link : nil)
            .allowsHitTesting(stop == .importing || stop == .agents || stop == .library || stop == .tour || stop == .makeDefault)
    }

    // MARK: Text column

    private var text: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DoneTile(stop: stop, done: done)
                    .anchorPreference(key: WelcomeTileAnchors.self, value: .center) { [stop: $0] }
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
            instruction
        }
        .foregroundStyle(.primary)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 20))
    }

    // MARK: Instruction

    private var tint: Color { Color(hue: stop.hue, saturation: 0.75, brightness: 0.82) }

    /// What to do, in the same small white card on every stop: a badge, one line saying the action,
    /// a hint under it, and the control or the gesture on the right.
    @ViewBuilder private var instruction: some View {
        switch stop {
        case .spaces:
            Instruction(kind: .tryIt, done: done, title: "Swipe to switch spaces") {
                HStack(spacing: 4) {
                    Text("or press").foregroundStyle(.secondary)
                    KeyCap(text: "⌃1"); KeyCap(text: "⌃2"); KeyCap(text: "⌃3")
                }
            } trailing: { Trackpad() } below: { EmptyView() }
        case .newTab, .commands:
            let t = stop == .newTab
            Instruction(kind: .tryIt, done: done, title: t ? "Press ⌘T to open anything" : "Press ⌘K to launch a plugin") {
                Text(t ? "Type a site, a search, or a tab's name" : "Radar, Comments and every plugin").foregroundStyle(.secondary)
            } trailing: {
                HStack(spacing: 4) { BigKey(text: "⌘"); BigKey(text: t ? "T" : "K") }
            } below: { EmptyView() }
        case .importing:
            ImportLead(done: done, skip: complete)
        case .tour:
            let filmPlaying = WelcomeFilm.shared.isPlaying
            Instruction(kind: .watch, done: done, title: "Watch the film") {
                Text("Under forty seconds, with sound.").foregroundStyle(.secondary)
            } trailing: {
                Button(action: act) {
                    Image(systemName: filmPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(tint))
                        .shadow(color: tint.opacity(0.4), radius: 6, y: 3)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filmPlaying ? "Pause the film" : "Play the film")
            } below: { EmptyView() }
        case .library:
            LibraryLead(done: done)
        case .agents:
            AgentsLead(done: done)
        case .makeDefault:
            Instruction(kind: .tryIt, done: done, title: done ? "Browsa is your default" : "Make Browsa your default") {
                Text(done ? "Links from everywhere open here." : "Click the menu on the right. macOS will ask you to confirm.").foregroundStyle(.secondary)
            } trailing: { EmptyView() } below: { EmptyView() }
        }
    }
}

/// The last stop breaks the gallery's layout: one clean card, everything centred, one button.
private struct DefaultCard: View {
    let done: Bool
    let complete: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                    .overlay(alignment: .bottomTrailing) {
                        if done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(red: 0.16, green: 0.7, blue: 0.33))
                                .offset(x: 6, y: 6)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
            }
            .anchorPreference(key: WelcomeTileAnchors.self, value: .center) { [.makeDefault: $0] }
            VStack(spacing: 6) {
                Text(done ? "Browsa is your default" : "Set Browsa as your default")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.6)
                Text(done ? "Links from Mail, Slack and everywhere else now open here."
                          : "Links from Mail, Slack and everywhere else will open here.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            if !done {
                Button {
                    asking = true
                    WelcomePage.makeDefaultBrowser { complete() }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        asking = false
                    }
                } label: {
                    Text("Make Default")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.62, green: 0.2, blue: 0.04))
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(.white, in: .capsule)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(asking)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                Text("macOS will ask you to confirm.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background { SurfaceBackground(surface: WelcomeStop.makeDefault.surface) }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        .animation(.smooth(duration: 0.4), value: done)
        .onAppear { if !done, WelcomePage.isDefaultBrowser { complete() } }
        .onChange(of: WelcomeDebug.shared.act?.id) {
            guard let a = WelcomeDebug.shared.act, a.stop == .makeDefault else { return }
            complete()
        }
    }
}

/// The instruction card every stop shares: a badge above a small white card with the action, a
/// hint under it, the control or gesture on the right, and choices below when there are any.
struct Instruction<Hint: View, Trailing: View, Below: View>: View {
    let kind: TryBadge.Kind
    let done: Bool
    let title: String
    @ViewBuilder let hint: Hint
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TryBadge(kind: kind, done: done)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
                        hint.font(.system(size: 11.5)).fixedSize()
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                below
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.95), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        }
        .environment(\.colorScheme, .light)
    }
}

/// A pick in an instruction card: a small white chip, outlined when chosen.
struct ChoiceChip<Icon: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder let icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon
                Text(title).font(.system(size: 11, weight: .medium)).fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.black.opacity(0.04), in: .capsule)
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.black.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: selected)
    }
}

/// The instruction card's main button, in the stop's colour.
struct ActionButton: View {
    let title: String
    let tint: Color
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(enabled ? tint : Color.black.opacity(0.18)))
                .shadow(color: tint.opacity(enabled ? 0.35 : 0), radius: 6, y: 3)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.smooth(duration: 0.2), value: enabled)
    }
}

/// A larger keycap for the shortcut instructions.
private struct BigKey: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 32, height: 32)
            .background(LinearGradient(colors: [.white, Color(white: 0.95)], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 0.8, y: 1.5)
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

/// "Try it", "Watch" or "Choose", or "Done" once learned: a small white pill above the instruction card.
struct TryBadge: View {
    enum Kind { case tryIt, watch, choose }
    let kind: Kind
    let done: Bool

    private var label: (String, String) {
        if done { return ("Done", "checkmark") }
        switch kind {
        case .tryIt: return ("Try it", "hand.tap.fill")
        case .watch: return ("Watch", "play.fill")
        case .choose: return ("Choose", "hand.point.up.left.fill")
        }
    }

    var body: some View {
        Label(label.0, systemImage: label.1)
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

// MARK: - Completion pulse

/// The green pulse that rolls out across the page when a stop is ticked off.
private struct PulseLayer: View {
    let anchors: [WelcomeStop: Anchor<CGPoint>]
    let proxy: GeometryProxy
    @State private var pulse = WelcomePulse.shared
    private let duration = 1.8

    var body: some View {
        if let stop = pulse.stop, let anchor = anchors[stop], !Motion.reduced {
            let origin = proxy[anchor]
            TimelineView(.animation) { context in
                let p = min(1, context.date.timeIntervalSince(pulse.started) / duration)
                Rectangle()
                    .colorEffect(ShaderLibrary.welcomePulse(.float2(proxy.size), .float2(origin), .float(p)))
            }
            .allowsHitTesting(false)
            .task(id: pulse.started) {
                let start = pulse.started
                try? await Task.sleep(for: .seconds(duration))
                pulse.end(start)
            }
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
