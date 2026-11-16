import SwiftUI
import AppKit
import BrowserCore

/// The window: sidebar and page on the space's tinted material, the command bar on top.
struct BrowserWindow: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var colorScheme
    /// Hides the peeking sidebar a moment after the pointer leaves it. Cancelled if the pointer comes
    /// back first, so a brief exit (a tooltip, a menu, the full-screen menu bar dropping over it)
    /// doesn't snap the sidebar away and back.
    @State private var peekHide: Task<Void, Never>?

    var body: some View {
        @Bindable var browser = browser
        let docked = browser.isSidebarDocked
        WindowColumns(browser: browser, sidebarDocked: docked, panelOpen: browser.panel != nil)
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
        .overlay {
            if let phase = browser.intro {
                IntroOverlay(phase: phase)
                    .transition(.identity)
            }
        }
        .animation(Motion.snappy, value: browser.commandBar)
        .animation(Motion.dock, value: browser.isSidebarDocked)
        .ignoresSafeArea()
        .background(WindowAccessor { window in configure(window) })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === browser.nsWindow { browser.library.markActive(browser) }
        }
        // Full screen swaps the sidebar's traffic lights for the title bar's, and AppKit rebuilds the
        // title bar on the way in and out.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            fullScreenChanged(note, to: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            fullScreenChanged(note, to: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            fullScreenChanged(note, to: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            fullScreenChanged(note, to: false)
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
            // Neutral until the intro reaches the sidebar, then the tint comes in.
            SpacePalette.color(for: browser.currentSpace)
                .opacity(browser.isIntroHoldingSidebar ? 0 : SpacePalette.surfaceOpacity(colorScheme))
                .animation(Motion.spring, value: browser.selectedSpaceID)
                .animation(.easeInOut(duration: 0.5), value: browser.isIntroHoldingSidebar)
        }
        .ignoresSafeArea()
    }

    /// With the sidebar hidden, pointing at the window's left edge slides it over the page, like Arc.
    @ViewBuilder private var peekingSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 10)
                .contentShape(.rect)
                .onHover { inside in
                    guard inside else { return }
                    peekHide?.cancel()
                    if !browser.isSidebarPeeking { withAnimation(Motion.peek) { browser.isSidebarPeeking = true } }
                }
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
                    .contentShape(.rect)
                    .onHover { inside in
                        peekHide?.cancel()
                        guard !inside else { return }
                        peekHide = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            // Still over it (the event was stale), or one of its popovers is open: wait
                            // until it really leaves, since no second "left" event will come.
                            while !Task.isCancelled, pointerOverPeekingSidebar || sidebarPopoverOpen {
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                            guard !Task.isCancelled else { return }
                            withAnimation(Motion.peek) { browser.isSidebarPeeking = false }
                        }
                    }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Where the pointer really is, rather than what the last hover event said. In full screen the
    /// pointer rests against the screen's edge, in the gap beside the floating sidebar, and a stale
    /// "left" event there used to hide the sidebar, which the edge then opened again: a flicker.
    private var pointerOverPeekingSidebar: Bool {
        guard let window = browser.nsWindow, let content = window.contentView else { return false }
        let p = window.mouseLocationOutsideOfEventStream
        // The sidebar plus its margin, from the window's left edge, full height.
        return p.x >= -1 && p.x <= browser.sidebarWidth + 12 && p.y >= 0 && p.y <= content.bounds.height
    }

    /// A popover from the sidebar (extensions, say) is open. It reaches past the sidebar, and hiding
    /// the sidebar under it would pull away its anchor.
    private var sidebarPopoverOpen: Bool {
        // Only popovers: in full screen the window also has AppKit's drop-down title bar as a child.
        browser.nsWindow?.childWindows?.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } == true
    }

    private func configure(_ window: NSWindow) {
        if browser.nsWindow !== window {
            browser.nsWindow = window
            // Each window keeps its own place; SwiftUI restores the frames.
            window.tabbingMode = .disallowed
            WindowSizing.attach(window)
        }
        // Only what changed: this runs on every update of the window's view, and resetting title bar
        // properties makes AppKit lay the title bar out again (in full screen, a visible flicker).
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
        // In a window the sidebar draws its own traffic lights (WindowButtons), which move with it,
        // so the title bar's are hidden. In full screen the title bar's drop down with the menu bar,
        // as in every app. AppKit rebuilds the title bar on the way in and out, so this runs then too.
        let fullScreen = window.styleMask.contains(.fullScreen) || browser.isFullScreen
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.isHidden == fullScreen else { continue }
            button.isHidden = !fullScreen
        }
    }

    private func fullScreenChanged(_ note: Notification, to fullScreen: Bool) {
        guard let window = note.object as? NSWindow, window === browser.nsWindow else { return }
        if browser.isFullScreen != fullScreen { browser.isFullScreen = fullScreen }
        configure(window)
        // AppKit finishes moving the title bar after the notification; check the buttons once more.
        DispatchQueue.main.async { configure(window) }
    }
}

/// Browser windows open filling the screen's free space. SwiftUI restores the last frame, which on
/// first runs is its small default, so until the person sizes a window themselves, each new window
/// is set to the screen's visible area. After they resize one, their size is left alone.
@MainActor
enum WindowSizing {
    private static let key = "windowSizedByPerson"
    private static var observing = false

    static func attach(_ window: NSWindow) {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // After SwiftUI has put back the saved frame.
        Task { @MainActor in
            guard let screen = window.screen ?? NSScreen.main, !window.styleMask.contains(.fullScreen) else { return }
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }
    }
}
