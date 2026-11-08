import AppKit
import SwiftUI
import BrowserCore

/// The welcome tab: a native page, not a web page, that Browsa opens on first launch.
enum Welcome {
    static let url = URL(string: "browsa://welcome")!
    static func isWelcome(_ url: URL?) -> Bool { url == Welcome.url }
}

/// The first-launch intro, in order. It plays on the real window, so nothing is swapped at the end:
/// the orb fills the window, then slowly washes out to the page colour while closing in on the page
/// card, the sidebar arrives, then a glow in the welcome tab brings up its cards.
enum IntroPhase: Int, Comparable {
    /// The orb fills the window, edge to edge under the traffic lights.
    case fill
    /// A slow wash to the page colour while the frame closes in on the page card, leaving the
    /// window around it neutral.
    case settle
    /// The frame takes the space's tint and the sidebar's contents come in.
    case sidebar
    /// A glow rises from the bottom of the welcome tab and its cards come up.
    case glow

    static func < (a: IntroPhase, b: IntroPhase) -> Bool { a.rawValue < b.rawValue }

    /// When each phase starts, in seconds from the beginning; `nil` is the end.
    static let timeline: [(IntroPhase?, Double)] = [(.settle, 1.6), (.sidebar, 4.2), (.glow, 4.9), (nil, 7.8)]
    /// How long the frame takes to close in on the page card, and the wash to reach the page colour.
    static let settleDuration = 2.6
    static let washDuration = 2.4
    /// The glow swells and sinks back over this long.
    static let glowDuration = 2.8
}

extension Browser {
    /// Before the sidebar's turn: its contents and the space tint wait.
    var isIntroHoldingSidebar: Bool { intro.map { $0 < .sidebar } ?? false }

    /// Opens the welcome tab (or goes to the one already open), optionally playing the intro.
    func openWelcome(playingIntro: Bool) {
        Preferences.hasSeenWelcome = true
        let space = currentSpace.isPrivate ? regularSpaces[0] : currentSpace
        if let existing = space.allTabs.first(where: { Welcome.isWelcome($0.url) }) {
            select(existing)
        } else {
            // Inserted without a URL so no web page is made for it, then marked as the welcome tab.
            let tab = library.insertTab(url: nil, in: space)
            tab.url = Welcome.url
            tab.title = "Welcome"
            select(tab)
        }
        if playingIntro { playIntro() }
    }

    /// Runs the intro's phases. Waits for the window to be on screen so the start isn't missed.
    func playIntro() {
        introTask?.cancel()
        guard !Motion.reduced else { intro = nil; return }
        commandBar = nil
        intro = .fill
        introTask = Task { @MainActor [weak self] in
            var waited = 0
            while self?.nsWindow?.isVisible != true, waited < 40 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            // A beat on the orb before anything moves.
            try? await Task.sleep(for: .milliseconds(250))
            let start = ContinuousClock.now
            for (phase, at) in IntroPhase.timeline {
                try? await Task.sleep(until: start + .milliseconds(Int(at * 1000)), clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.intro = phase
            }
        }
    }

    /// A click or a key during the intro jumps to the end.
    func skipIntro() {
        introTask?.cancel()
        introTask = nil
        withAnimation(Motion.snappy) { intro = nil }
    }

    /// The page card's frame in the window, top-left origin, for the intro to settle onto.
    func pageCardFrame() -> CGRect? {
        guard let view = pageCardView, let content = view.window?.contentView else { return nil }
        let r = view.convert(view.bounds, to: content)
        guard r.width > 0, r.height > 0 else { return nil }
        let top = content.isFlipped ? r.minY : content.bounds.height - r.maxY
        return CGRect(x: r.minX, y: top, width: r.width, height: r.height)
    }
}

/// Marks the page card's place so the intro can find it in window coordinates.
struct PageCardMarker: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        browser.pageCardView = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if browser.pageCardView !== v { browser.pageCardView = v }
    }
}

/// Sidebar content that waits for its turn in the intro, then slides in a beat after the row above.
private struct IntroArrival: ViewModifier {
    @Environment(Browser.self) private var browser
    let index: Int

    func body(content: Content) -> some View {
        let waiting = browser.isIntroHoldingSidebar
        content
            .opacity(waiting ? 0 : 1)
            .offset(x: waiting ? -14 : 0)
            .animation(waiting ? nil : Motion.spring.delay(Double(index) * 0.045), value: waiting)
    }
}

extension View {
    func introArrival(_ index: Int) -> some View { modifier(IntroArrival(index: index)) }
}
