import SwiftUI
import AppKit
import WebKit
import BrowserCore
import BrowserEngine
import Extensibility

/// The page, as a card inset into the window, with its progress line, error page, find bar and toasts.
struct PageArea: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if browser.currentTab.map({ Welcome.isWelcome($0.url) }) == true {
                WelcomePage()
            } else if browser.currentTab.map({ LibraryPage.isLibrary($0.url) }) == true {
                LibraryView()
            } else if let tab = browser.currentTab {
                let focuses = browser.commandBar == nil && browser.find == nil && browser.glance == nil
                if browser.isReaderShowing, let reader = browser.reader {
                    PageHost(view: reader.page.view, focusesPage: focuses, holdsWidth: browser.isSidebarMoving)
                } else {
                    PageHost(view: browser.controller(for: tab).page.view, focusesPage: focuses,
                             holdsWidth: browser.isSidebarMoving)
                }
                if let server = RadarStore.shared.server(for: tab.url), !server.isUp, !browser.isReaderShowing {
                    RadarStoppedPage(server: server)
                } else if let error = tab.loadError, !browser.isReaderShowing {
                    ErrorPage(error: error)
                }
            } else {
                EmptyPage()
            }
        }
        .clipShape(.rect(cornerRadius: PageCard.radius, style: .continuous))
        // The shadow belongs to a plain shape behind the page. On the page itself it would be
        // redrawn offscreen every frame while the page resizes.
        .background {
            RoundedRectangle(cornerRadius: PageCard.radius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .overlay(alignment: .top) {
            // Clipped to the card, so the line follows its rounded top corners.
            if let tab = browser.currentTab {
                ProgressLine(isLoading: tab.isLoading, progress: tab.estimatedProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(.rect(cornerRadius: PageCard.radius, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { AgentPageOverlay() }
        .overlay(alignment: .top) {
            if let url = browser.currentTab?.url, !browser.isReaderShowing { StoreInstallBanner(pageURL: url, pageTitle: browser.currentTab?.title ?? "").padding(.top, 10) }
        }
        .overlay(alignment: .topTrailing) {
            if browser.isReaderShowing {
                ReaderControls()
                    .padding(10)
                    .transition(.opacity)
            } else if browser.find != nil {
                FindBar()
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = browser.toast {
                HStack(spacing: 12) {
                    Text(toast)
                    ForEach(browser.toastActions) { action in
                        Button(action.title) { browser.runToastAction(action) }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(PanelFill(), in: .capsule)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast)
            }
        }
        .overlay(alignment: .bottomTrailing) { CallCapsule().padding(12) }
        .overlay {
            if let glance = browser.glance {
                GlanceOverlay(glance: glance)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Motion.snappy, value: browser.glance?.id)
        .animation(Motion.snappy, value: browser.toast)
        .animation(Motion.snappy, value: browser.find != nil)
        .animation(Motion.snappy, value: browser.isReaderShowing)
    }
}

/// The page card's shape and its distance from the window edge.
enum PageCard {
    static let radius: CGFloat = 10
    static let inset: CGFloat = 6
}

/// Reader's text size and a way out, floating over the article.
private struct ReaderControls: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 12) {
            Button { browser.zoom(-1) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller Text (⌘-)")
            Button { browser.zoom(1) } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger Text (⌘+)")
            Divider().frame(height: 14)
            Button { browser.closeReader() } label: { Image(systemName: "doc.plaintext.fill") }
                .help(Shortcuts.shared.help("Hide Reader", .reader))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(PanelFill(), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Holds the current page's view. Switching tabs swaps the view inside, so pages aren't rebuilt.
///
/// While the sidebar docks or hides (`holdsWidth`), the page keeps the widest size it will have and
/// the card clips it, so the web view lays out once instead of on every frame of the animation.
struct PageHost: NSViewRepresentable {
    let view: NSView
    let focusesPage: Bool
    var holdsWidth = false

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.show(view, focus: focusesPage)
        container.holdsWidth = holdsWidth
    }

    final class Container: NSView {
        var holdsWidth = false {
            didSet { if holdsWidth != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = PageCard.radius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func show(_ page: NSView, focus: Bool) {
            if page.superview !== self {
                subviews.forEach { $0.removeFromSuperview() }
                page.removeFromSuperview()
                page.translatesAutoresizingMaskIntoConstraints = true
                page.autoresizingMask = []
                addSubview(page)
                layoutPage()
                if focus { focusPage(page) }
            }
        }

        override func layout() {
            super.layout()
            layoutPage()
        }

        /// Pinned to the leading edge, so the page moves with the card's edge and the far side is
        /// clipped rather than squeezed.
        private func layoutPage() {
            guard let page = subviews.first else { return }
            var width = bounds.width
            if holdsWidth, let window {
                width = max(width, window.contentLayoutRect.width - PageCard.inset * 2)
            }
            let frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            if page.frame != frame { page.frame = frame }
        }

        // MARK: Hover while Browsa isn't in front

        /// WebKit only follows the pointer in the key window of the active app, so in Safari a link doesn't light up
        /// until you click into the window. Chrome and Arc show hover in any window, and so does Browsa: while this
        /// window isn't the key window of the active app, its own tracking area passes the pointer to the page.
        private var hoverArea: NSTrackingArea?
        /// The page last told the pointer was over it, to tell when it leaves.
        private weak var hoveredPage: WKWebView?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        /// WebKit is following the pointer itself.
        private var webKitTracks: Bool { NSApp.isActive && window?.isKeyWindow == true }

        override func mouseMoved(with event: NSEvent) { forwardHover(event) }
        override func mouseEntered(with event: NSEvent) { forwardHover(event) }
        override func mouseExited(with event: NSEvent) { leaveHover() }

        /// Set while handing an event to the page. A web view that doesn't take an event passes it back up the
        /// responder chain to this view, which mustn't hand it on again.
        private var isForwarding = false

        /// Only moves are passed on: WebKit works out entering and leaving links from those itself.
        private func forwardHover(_ event: NSEvent) {
            guard !isForwarding, event.trackingArea === hoverArea else { return }
            guard !webKitTracks else { hoveredPage = nil; return }
            // Only the page that's actually under the pointer, not one covered by the find bar or a panel.
            let page = pageUnderPointer(event)
            if hoveredPage !== page { leaveHover() }
            guard let page, let moved = Self.moveEvent(like: event) else { return }
            hoveredPage = page
            isForwarding = true
            defer { isForwarding = false }
            page.mouseMoved(with: moved)
        }

        /// When the pointer leaves, the page hears it left, so a link stops highlighting as with WebKit's own exit.
        private func leaveHover() {
            guard !isForwarding, let page = hoveredPage else { return }
            hoveredPage = nil
            guard !webKitTracks, let window = page.window,
                  let exited = NSEvent.enterExitEvent(with: .mouseExited, location: window.mouseLocationOutsideOfEventStream,
                                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      trackingNumber: 0, userData: nil) else { return }
            isForwarding = true
            defer { isForwarding = false }
            page.mouseExited(with: exited)
        }

        /// Entered and exited events become a plain move at the same spot.
        private static func moveEvent(like event: NSEvent) -> NSEvent? {
            if event.type == .mouseMoved { return event }
            return NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                      timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 0, pressure: 0)
        }

        private func pageUnderPointer(_ event: NSEvent) -> WKWebView? {
            guard let content = window?.contentView, let frame = content.superview ?? Optional(content) else { return nil }
            var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let v = view, v !== self {
                if let web = v as? WKWebView { return web }
                view = v.superview
            }
            return nil
        }

        /// Keys go to the page after a tab switch, so Space scrolls and arrows work straight away.
        private func focusPage(_ page: NSView) {
            Task { @MainActor [weak page] in
                guard let page, let window = page.window else { return }
                if !(window.firstResponder is NSTextView) { window.makeFirstResponder(page) }
            }
        }
    }
}

/// A hairline of progress along the top of the page while it loads.
struct ProgressLine: View {
    let isLoading: Bool
    let progress: Double

    var body: some View {
        let visible = isLoading && progress < 1
        Rectangle()
            .fill(.tint)
            .frame(height: 2)
            .scaleEffect(x: max(0.05, progress), y: 1, anchor: .leading)
            .animation(.easeOut(duration: 0.2), value: progress)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: visible ? 0.1 : 0.4), value: visible)
        .allowsHitTesting(false)
    }
}

private struct ErrorPage: View {
    @Environment(Browser.self) private var browser
    let error: LoadError

    private var host: String? { error.url?.host() }
    private var isLocal: Bool { host.map { LocalNetwork.contains(host: $0) } ?? false }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: error.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(error.title).font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let url = error.url {
                Text(url.absoluteString).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                if error.canRetry {
                    Button("Try Again") { browser.reload() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Go Back") { browser.goBack() }
                        .keyboardShortcut(.defaultAction)
                    if error.canVisitAnyway {
                        Button("Visit Anyway") { browser.visitAnyway() }
                    }
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 6)
            if error.canVisitAnyway {
                Text(isLocal
                     ? "Browsa will remember this certificate for \(host ?? "this site"). To allow every device on your network, turn on Settings > Privacy > Allow local network sites with certificate errors."
                     : "Browsa will remember this certificate for \(host ?? "this site"). If the site shows a different one, you'll be asked again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Certificate failures say what's wrong in plain words; the rest use the system's message.
    private var detail: String {
        guard error.kind == .insecure, error.canVisitAnyway else { return error.detail }
        return isLocal
            ? "Your Mac doesn't trust this site's certificate. That's normal for devices on your own network, like a router or Home Assistant."
            : "Your Mac doesn't trust this site's certificate. Someone could be pretending to be this site, so only continue if you know it."
    }
}

/// Nothing open in this space.
private struct EmptyPage: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: browser.currentSpace.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(SpacePalette.color(for: browser.currentSpace).opacity(0.6))
            Text(browser.currentSpace.name).font(.title3.weight(.semibold))
            Button { browser.showCommandBar(.newTab) } label: {
                HStack(spacing: 6) {
                    Text("New Tab")
                    if let key = Shortcuts.shared.display(.newTab) { Text(key).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Find

private struct FindBar: View {
    @Environment(Browser.self) private var browser
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var browser = browser
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on page", text: Binding(
                get: { browser.find?.text ?? "" },
                // Closing tears the field down, which can write once more; without the guard that
                // write ran findNext, which reopened the bar it had just closed.
                set: { guard browser.find != nil else { return }
                       browser.find?.text = $0; browser.find?.found = nil; browser.find?.matches = nil
                       browser.findNext() }))
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { browser.findNext() }
                .onKeyPress(.escape) { browser.closeFind(); return .handled }
            if browser.find?.found == false {
                Text("Not found").font(.caption).foregroundStyle(.secondary)
            } else if let m = browser.find?.matches, m.total > 0 {
                let total = m.capped ? "\(m.total)+" : "\(m.total)"
                Text(m.current > 0 ? "\(m.current) of \(total)" : "\(total) found")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button { browser.findNext(backwards: true) } label: { FindButtonLabel(symbol: "chevron.up") }
                .buttonStyle(.plain).help(Shortcuts.shared.help("Previous", .findPrevious))
            Button { browser.findNext() } label: { FindButtonLabel(symbol: "chevron.down") }
                .buttonStyle(.plain).help(Shortcuts.shared.help("Next", .findNext))
            Button { browser.closeFind() } label: { FindButtonLabel(symbol: "xmark") }
                .buttonStyle(.plain).help("Done (Esc)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(PanelFill(), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .onAppear { focused = true }
        .onChange(of: browser.findFocusRequest) { focused = true }
    }
}

/// A find bar button that answers clicks across its whole square, not just the glyph.
private struct FindButtonLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 22, height: 22)
            .contentShape(.rect)
    }
}

/// On a Chrome Web Store or Firefox Add-ons page, which only offer to install into their own browser:
/// a glass bar naming the extension, whether it's been checked in Browsa, and Add to Browsa. After
/// adding, the same bar confirms it and offers to pin it to the address pill.
private struct StoreInstallBanner: View {
    let pageURL: URL
    let pageTitle: String
    @Environment(Browser.self) private var browser
    @State private var preview: Library.ExtensionPreview?
    @State private var working = false
    @State private var problem: String?
    /// Set once added, until the page changes.
    @State private var added: InstalledExtension?

    private var source: ExtensionSource? {
        guard let host = pageURL.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" || host == "addons.mozilla.org" else { return nil }
        return ExtensionSource(link: pageURL.absoluteString)
    }

    /// The extension's name from the store page's title, before anything is downloaded.
    private var name: String? {
        let cut = [" - Chrome Web Store", " \u{2013} Get this Extension", " \u{2013} Get this Add-on", " – Add-ons for Firefox"]
        var title = pageTitle
        for suffix in cut { if let r = title.range(of: suffix) { title = String(title[..<r.lowerBound]) } }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title.lowercased().contains("chrome web store") ? nil : title
    }

    var body: some View {
        Group {
            if let added, added.source == source {
                addedBar(added)
            } else if let source, !browser.library.extensionCatalog.items.contains(where: { $0.source == source }) {
                offerBar(source)
            }
        }
        .sheet(item: $preview) { p in
            AddExtensionSheet(preview: p) {
                browser.library.install(p)
                preview = nil
                withAnimation(Motion.snappy) { added = p.item }
            } cancel: { preview = nil }
        }
        .onChange(of: pageURL) { added = nil; problem = nil }
    }

    private func offerBar(_ source: ExtensionSource) -> some View {
        bar {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? "Add this extension to Browsa")
                    .font(.headline).lineLimit(1)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    VerifiedLine(isVerified: VerifiedExtensions.contains(source))
                }
            }
            Spacer(minLength: 12)
            Button(action: fetch) {
                HStack(spacing: 6) {
                    if working { ProgressView().controlSize(.small) }
                    Text(working ? "Getting…" : "Add to Browsa")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(working)
        }
    }

    private func addedBar(_ item: InstalledExtension) -> some View {
        let loaded = browser.library.extensions.first { $0.id == item.id }
        let pinned = loaded.map(browser.library.isPinned) ?? false
        return bar {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.name) is in Browsa").font(.headline).lineLimit(1)
                Text(loaded == nil ? "Starting it up…"
                     : pinned ? "Pinned to the address bar."
                     : loaded?.hasAction == true ? "Find it in the address bar's extensions menu."
                     : "It runs on the pages it works with.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let loaded, loaded.hasAction, !pinned {
                Button("Pin to Address Bar") { browser.library.setPinned(loaded, true) }
                    .buttonStyle(.glass)
            }
            Button("Done") { withAnimation(Motion.snappy) { added = nil } }
                .buttonStyle(.glassProminent)
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .frame(maxWidth: 560)
            // Glass alone lets busy store headers show through the text; a material under it keeps it legible.
            .background(.regularMaterial, in: .capsule)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func fetch() {
        working = true
        problem = nil
        Task {
            do { preview = try await browser.library.previewExtension(link: pageURL.absoluteString) }
            catch { problem = "Couldn't get it: \(error.localizedDescription)" }
            working = false
        }
    }
}

/// The checked-in-Browsa line under an extension's name.
private struct VerifiedLine: View {
    let isVerified: Bool

    var body: some View {
        Label {
            Text(isVerified ? "Works in Browsa" : "Not tested in Browsa yet").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: isVerified ? "checkmark.seal.fill" : "questionmark.circle")
                .foregroundStyle(isVerified ? Color.green : Color.secondary)
        }
        .font(.caption)
    }
}
