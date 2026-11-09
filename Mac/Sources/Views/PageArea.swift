import SwiftUI
import AppKit
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
            } else if let tab = browser.currentTab {
                let focuses = browser.commandBar == nil && browser.find == nil
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
            if let tab = browser.currentTab { ProgressLine(tab: tab) }
        }
        .overlay(alignment: .top) {
            if let url = browser.currentTab?.url, !browser.isReaderShowing { StoreInstallBanner(pageURL: url).padding(.top, 10) }
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
                Text(toast)
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
        .animation(Motion.snappy, value: browser.toast)
        .animation(Motion.snappy, value: browser.find != nil)
        .animation(Motion.snappy, value: browser.isReaderShowing)
    }
}

/// The page card's shape and its distance from the window edge.
enum PageCard {
    static let radius: CGFloat = 9
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
                .help("Hide Reader (⇧⌘R)")
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
private struct ProgressLine: View {
    let tab: BrowserTab

    var body: some View {
        let visible = tab.isLoading && tab.estimatedProgress < 1
        Rectangle()
            .fill(.tint)
            .frame(height: 2)
            .scaleEffect(x: max(0.05, tab.estimatedProgress), y: 1, anchor: .leading)
            .animation(.easeOut(duration: 0.2), value: tab.estimatedProgress)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: visible ? 0.1 : 0.4), value: visible)
        .allowsHitTesting(false)
    }
}

private struct ErrorPage: View {
    @Environment(Browser.self) private var browser
    let error: LoadError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: error.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(error.title).font(.title2.weight(.semibold))
            Text(error.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let url = error.url {
                Text(url.absoluteString).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            if error.canRetry {
                Button("Try Again") { browser.reload() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .padding(.top, 6)
            } else {
                Button("Go Back") { browser.goBack() }
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
                    Text("⌘T").foregroundStyle(.secondary)
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
                set: { browser.find?.text = $0; browser.find?.found = nil; browser.findNext() }))
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { browser.findNext() }
                .onKeyPress(.escape) { browser.closeFind(); return .handled }
            if browser.find?.found == false {
                Text("Not found").font(.caption).foregroundStyle(.secondary)
            }
            Button { browser.findNext(backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).help("Previous (⇧⌘G)")
            Button { browser.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).help("Next (⌘G)")
            Button { browser.closeFind() } label: { Image(systemName: "xmark") }
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


/// On a Chrome Web Store or Firefox Add-ons page, which only offer to install into their own browser:
/// the same add flow as Settings > Extensions, from the page.
private struct StoreInstallBanner: View {
    let pageURL: URL
    @Environment(Browser.self) private var browser
    @State private var preview: Library.ExtensionPreview?
    @State private var working = false
    @State private var problem: String?

    private var source: ExtensionSource? {
        guard let host = pageURL.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" || host == "addons.mozilla.org" else { return nil }
        return ExtensionSource(link: pageURL.absoluteString)
    }

    var body: some View {
        if let source, !browser.library.extensionCatalog.items.contains(where: { $0.source == source }) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                Text(problem ?? "This page only installs into its own browser.")
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                Button(working ? "Getting…" : "Add to Browsa…", action: fetch)
                    .disabled(working)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(PanelFill(), in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .sheet(item: $preview) { p in
                AddExtensionSheet(preview: p) { browser.library.install(p); preview = nil } cancel: { preview = nil }
            }
        }
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
