import SwiftUI
import AppKit
import BrowserCore
import BrowserEngine

/// The page, as a card inset into the window, with its progress line, error page, find bar and toasts.
struct PageArea: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if let tab = browser.currentTab {
                let controller = browser.controller(for: tab)
                PageHost(view: controller.page.view, focusesPage: browser.commandBar == nil && browser.find == nil)
                if let error = tab.loadError {
                    ErrorPage(error: error)
                }
            } else {
                EmptyPage()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .top) {
            if let tab = browser.currentTab { ProgressLine(tab: tab) }
        }
        .overlay(alignment: .topTrailing) {
            if browser.find != nil {
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
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast)
            }
        }
        .animation(Motion.snappy, value: browser.toast)
        .animation(Motion.snappy, value: browser.find != nil)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// Holds the current page's view. Switching tabs swaps the view inside, so pages aren't rebuilt.
struct PageHost: NSViewRepresentable {
    let view: NSView
    let focusesPage: Bool

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.show(view, focus: focusesPage)
    }

    final class Container: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func show(_ page: NSView, focus: Bool) {
            if page.superview !== self {
                subviews.forEach { $0.removeFromSuperview() }
                page.removeFromSuperview()
                page.translatesAutoresizingMaskIntoConstraints = false
                addSubview(page)
                NSLayoutConstraint.activate([
                    page.leadingAnchor.constraint(equalTo: leadingAnchor),
                    page.trailingAnchor.constraint(equalTo: trailingAnchor),
                    page.topAnchor.constraint(equalTo: topAnchor),
                    page.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                if focus { focusPage(page) }
            }
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
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .onChange(of: browser.findFocusRequest) { focused = true }
    }
}
