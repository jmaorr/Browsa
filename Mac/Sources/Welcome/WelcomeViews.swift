import SwiftUI
import AppKit

/// The intro's first two phases, over the whole window: the orb, then a slow wash to the page colour
/// while the frame closes in on the page card. The orb stays still in the window and the closing
/// frame clips it. It ends exactly on the real card, then steps aside.
struct IntroOverlay: View {
    @Environment(Browser.self) private var browser
    let phase: IntroPhase
    @State private var start = Date.now

    var body: some View {
        GeometryReader { proxy in
            let full = CGRect(origin: .zero, size: proxy.size)
            let settling = phase >= .settle
            let card = browser.pageCardFrame() ?? full.insetBy(dx: PageCard.inset, dy: PageCard.inset)
            let rect = settling ? card : full
            ZStack {
                TimelineView(.animation) { context in
                    Rectangle()
                        .colorEffect(ShaderLibrary.orbFill(.float2(proxy.size),
                                                           .float(context.date.timeIntervalSince(start))))
                }
                Color(nsColor: .textBackgroundColor)
                    .opacity(settling ? 1 : 0)
                    .animation(.easeInOut(duration: IntroPhase.washDuration), value: settling)
            }
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: settling ? PageCard.radius : 0, style: .continuous)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeInOut(duration: IntroPhase.settleDuration), value: settling)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { browser.skipIntro() }
        .accessibilityLabel("Welcome to Browsa")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the introduction")
    }
}

/// The welcome tab's page. During the intro its content waits for the glow, then comes up.
struct WelcomePage: View {
    @Environment(Browser.self) private var browser
    @State private var glowStart: Date?

    private var shown: Bool { browser.intro == nil || browser.intro == .glow }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if browser.intro == .glow, let glowStart {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(glowStart)
                    GeometryReader { proxy in
                        Rectangle()
                            .colorEffect(ShaderLibrary.orbGlow(.float2(proxy.size), .float(t + 4),
                                                               .float(min(1, t / IntroPhase.glowDuration))))
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            content
        }
        .onChange(of: browser.intro) { _, new in
            if new == .glow { glowStart = .now }
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("Welcome to Browsa")
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-0.8)
                    .welcomeArrival(0, shown: shown, distance: 10)
                Text("A calmer way to keep the web open.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .welcomeArrival(1, shown: shown, distance: 10)
            }
            LazyVGrid(columns: [GridItem(.fixed(270), spacing: 14), GridItem(.fixed(270), spacing: 14)], spacing: 14) {
                WelcomeCard(title: "Open anything", detail: "Search, type an address or jump to a tab you already have.",
                            keys: "⌘T") { browser.showCommandBar(.newTab) }
                    .welcomeArrival(2, shown: shown)
                WelcomeCard(title: "Tools and commands", detail: "Everything Browsa can do, one shortcut away.",
                            keys: "⌘K") { browser.showCommandBar(.commands) }
                    .welcomeArrival(3, shown: shown)
                WelcomeCard(title: "Spaces keep things apart", detail: "Each space has its own tabs and colour. Swipe with two fingers to switch.",
                            keys: nil) { browser.selectAdjacentSpace(1) }
                    .welcomeArrival(4, shown: shown)
                WelcomeCard(title: "Make Browsa your browser", detail: "Links from other apps will open here.",
                            keys: nil) { WelcomePage.makeDefaultBrowser() }
                    .welcomeArrival(5, shown: shown)
            }
        }
        .padding(40)
    }

    /// Asks macOS to make Browsa the default browser. macOS confirms with the person first.
    static func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
    }
}

private struct WelcomeCard: View {
    let title: String
    let detail: String
    let keys: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    if let keys {
                        Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(.primary.opacity(hovering ? 0.06 : 0.035), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
    }
}

/// Welcome content rising into place, each piece a beat after the last, once the glow starts.
private struct WelcomeArrival: ViewModifier {
    let index: Int
    let shown: Bool
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : distance)
            .scaleEffect(shown || Motion.reduced ? 1 : 0.98)
            .animation(shown ? (Motion.reduced ? Motion.spring : .smooth(duration: 0.9)).delay(0.6 + Double(index) * 0.1) : nil, value: shown)
    }
}

private extension View {
    func welcomeArrival(_ index: Int, shown: Bool, distance: CGFloat = 18) -> some View {
        modifier(WelcomeArrival(index: index, shown: shown, distance: distance))
    }
}
