import SwiftUI
import AppKit
import BrowserEngine

/// Glance: Option-click a link to look at it in a card over the page, like Zen's Glance and Arc's
/// Peek. Esc (or a click outside) puts it away; ⌘Return or the expand button makes it a tab.
@MainActor @Observable
final class GlanceSession: Identifiable, EnginePageDelegate {
    let id = UUID()
    let page: any EnginePage
    let isPrivate: Bool
    @ObservationIgnored weak var browser: Browser?

    init(url: URL, isPrivate: Bool, browser: Browser) {
        self.isPrivate = isPrivate
        self.browser = browser
        page = browser.engine.makePage(options: PageOptions(profile: isPrivate ? .ephemeral : .standard, url: url),
                                       delegate: GlanceSession.placeholder)
        page.delegate = self
    }

    /// makePage needs a delegate before `self` exists.
    private static let placeholder = PlaceholderDelegate()
    private final class PlaceholderDelegate: EnginePageDelegate {}

    var url: URL? { page.state.url }

    // Links inside the Glance stay in it; new windows become tabs.
    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        if request.wantsNewTab {
            browser?.newTab(url: request.url, isPrivate: isPrivate, source: .link, select: request.wantsForeground)
            return .cancel
        }
        return .allow
    }

    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? {
        if let url { browser?.newTab(url: url, isPrivate: isPrivate, source: .link) }
        return nil
    }

    func pageDidRequestClose(_ page: any EnginePage) { browser?.closeGlance() }
}

extension Browser {
    func openGlance(_ url: URL, isPrivate: Bool) {
        glance?.page.close()
        glance = GlanceSession(url: url, isPrivate: isPrivate, browser: self)
    }

    func closeGlance() {
        glance?.page.close()
        glance = nil
    }

    /// Keeps it: a new tab for what the Glance shows now.
    func expandGlance() {
        guard let g = glance else { return }
        let url = g.url
        closeGlance()
        if let url { newTab(url: url, isPrivate: g.isPrivate, source: .link) }
    }
}

struct GlanceOverlay: View {
    @Environment(Browser.self) private var browser
    let glance: GlanceSession
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(.rect)
                .onTapGesture { browser.closeGlance() }
            VStack(spacing: 0) {
                header
                PageHost(view: glance.page.view, focusesPage: true)
                    .overlay(alignment: .top) {
                        if glance.page.state.isLoading {
                            ProgressView(value: max(0.05, glance.page.state.progress))
                                .progressViewStyle(.linear).tint(.accentColor).frame(height: 2)
                        }
                    }
            }
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .padding(.horizontal, 44)
            .padding(.vertical, 28)
        }
        .onAppear(perform: watchKeys)
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let url = glance.url { FaviconView(url: url, size: 14, isPrivate: glance.isPrivate) }
            VStack(alignment: .leading, spacing: 0) {
                Text(glance.page.state.title.isEmpty ? "Loading…" : glance.page.state.title)
                    .font(.callout.weight(.medium)).lineLimit(1)
                if let host = glance.url?.host() {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { browser.expandGlance() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Open as a Tab (⌘Return)")
            Button { browser.closeGlance() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(PanelFill())
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    /// Esc closes, ⌘Return keeps it as a tab, while this window is key.
    private func watchKeys() {
        let window = browser.nsWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            if event.keyCode == 53 {
                MainActor.assumeIsolated { browser.closeGlance() }
                return nil
            }
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { browser.expandGlance() }
                return nil
            }
            return event
        }
    }
}
