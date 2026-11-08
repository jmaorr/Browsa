import SwiftUI
import AppKit
import BrowserCore

/// The window: sidebar and page on the space's tinted material, the command bar on top.
struct BrowserWindow: View {
    @Environment(Browser.self) private var browser
    @State private var dragStartWidth: CGFloat?
    @State private var panelDragStartWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var browser = browser
        let docked = browser.isSidebarDocked
        HStack(spacing: 0) {
            if docked {
                Sidebar()
                    .frame(width: browser.sidebarWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            PageArea()
                .padding(.vertical, PageCard.inset)
                .padding(.trailing, PageCard.inset)
                .padding(.leading, docked ? 0 : PageCard.inset)
            if let panel = browser.panel {
                RightPanel(kind: panel)
                    .frame(width: browser.panelWidth)
                    .padding(.vertical, PageCard.inset)
                    .padding(.trailing, PageCard.inset)
                    .overlay(alignment: .leading) { panelResizeHandle }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.dock, value: browser.panel)
        .background { background }
        .overlay(alignment: .leading) {
            if !docked { peekingSidebar }
        }
        .overlay {
            if let mode = browser.commandBar {
                CommandBar(mode: mode)
                    .id(mode)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(Motion.snappy, value: browser.commandBar)
        .animation(Motion.dock, value: browser.isSidebarDocked)
        .ignoresSafeArea()
        .background(WindowAccessor { window in configure(window) })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === browser.nsWindow { browser.library.markActive(browser) }
        }
        .sheet(item: Binding(
            get: { browser.activePrompt },
            // Dismissed without a button (Esc): answer it, so the page isn't left waiting.
            set: { if $0 == nil, browser.activePrompt != nil { browser.answer(.cancel) } })) { prompt in
            PromptSheet(prompt: prompt)
                .environment(browser)
        }
        .sheet(isPresented: $browser.isArchivePresented) {
            ArchiveSheet().environment(browser)
        }
        .onChange(of: browser.selectedSpaceID) { browser.isSidebarPeeking = false }
    }

    /// The space's colour, lightly, over the window material. It tints the sidebar and the frame
    /// around the page, never the icons or the page itself.
    private var background: some View {
        ZStack {
            WindowMaterial(material: .sidebar)
            SpacePalette.color(for: browser.currentSpace)
                .opacity(SpacePalette.surfaceOpacity(colorScheme))
                .animation(Motion.spring, value: browser.selectedSpaceID)
        }
        .ignoresSafeArea()
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? browser.sidebarWidth
                        dragStartWidth = start
                        browser.sidebarWidth = min(420, max(200, start + value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil })
            .offset(x: 4)
    }

    /// Dragging the panel's left edge. The page narrows to match; it's never covered.
    private var panelResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = panelDragStartWidth ?? browser.panelWidth
                        panelDragStartWidth = start
                        browser.panelWidth = min(560, max(240, start - value.translation.width))
                    }
                    .onEnded { _ in panelDragStartWidth = nil })
            .offset(x: -7)
    }

    /// With the sidebar hidden, pointing at the window's left edge slides it over the page, like Arc.
    @ViewBuilder private var peekingSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 10)
                .contentShape(.rect)
                .onHover { if $0 { withAnimation(Motion.peek) { browser.isSidebarPeeking = true } } }
            if browser.isSidebarPeeking {
                Sidebar(isFloating: true)
                    .frame(width: browser.sidebarWidth)
                    .background {
                        ZStack {
                            WindowMaterial(material: .popover)
                            SpacePalette.color(for: browser.currentSpace).opacity(SpacePalette.surfaceOpacity(colorScheme))
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 4)
                    .padding(6)
                    .onHover { inside in
                        guard !inside else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            withAnimation(Motion.peek) { browser.isSidebarPeeking = false }
                        }
                    }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func configure(_ window: NSWindow) {
        if browser.nsWindow !== window {
            browser.nsWindow = window
            // Each window keeps its own place; SwiftUI restores the frames.
            window.tabbingMode = .disallowed
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        // The traffic lights live in the sidebar, so they go when it does.
        let showLights = browser.isSidebarDocked
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !showLights
        }
    }
}
