import AppKit
import BrowserCore
import BrowserEngine
import os

private let videoPiPLog = Logger(subsystem: "com.orriginal.browsa", category: "videoPiP")

/// Picture in picture for any video, on top of macOS's own floating video window.
///
/// - Leaving a tab while its video plays with sound pops the video out, so it follows you around, like Arc.
///   Coming back to the tab puts it back in the page. Calls don't: they have their own window (`CallPiP`).
/// - ⌥⌘P, the command bar and the sidebar's button pop the video out or back in by hand, whatever tab it's in.
/// - The video window's "back to tab" button brings its tab forward.
///
/// Sites that switch picture in picture off for their player get it anyway. Settings › General can turn the
/// popping out on tab switches off (`videoPiPOnTabSwitch`).
@MainActor
final class VideoPiP {
    nonisolated static let autoKey = "videoPiPOnTabSwitch"

    private unowned let library: Library
    /// Tabs whose video popped out because you left them. Going back puts the video back.
    private var poppedOut: Set<UUID> = []

    init(library: Library) {
        self.library = library
        UserDefaults.standard.register(defaults: [Self.autoKey: true])
    }

    private var popsOutOnTabSwitch: Bool { UserDefaults.standard.bool(forKey: Self.autoKey) }

    // MARK: Switching tabs

    /// A window moved from one tab to another (a click, a shortcut, another space, a tab closing). Called
    /// before the window draws the new tab, so the video starts to pop out while its page is still on screen.
    func shownTabChanged(from old: BrowserTab?, to new: BrowserTab?) {
        if let new, poppedOut.remove(new.id) != nil, new.media.isPictureInPicture {
            library.existingController(for: new)?.page.media(.exitPictureInPicture)
        }
        guard popsOutOnTabSwitch, let old, old.id != new?.id,
              // Closing the tab: the video goes with it.
              old.id != library.closingTabID, library.space(containing: old) != nil,
              // Still on screen in another window, or in a call (that has its own window).
              library.window(showing: old) == nil, old.call == nil,
              old.media.isWatching, !old.media.isPictureInPicture,
              let controller = library.existingController(for: old) else { return }
        videoPiPLog.info("Popping out the video of a tab you left")
        controller.page.media(.enterPictureInPicture)
        poppedOut.insert(old.id)
    }

    // MARK: By hand

    /// Pops a tab's video out, or back in if it's out.
    func toggle(_ tab: BrowserTab) {
        guard let controller = library.existingController(for: tab) else { return }
        // Put back by hand: switching back to the tab shouldn't do it again.
        poppedOut.remove(tab.id)
        controller.page.media(.togglePictureInPicture)
    }

    func playPause(_ tab: BrowserTab) {
        library.existingController(for: tab)?.page.media(.playPause)
    }

    // MARK: The video window's own buttons

    /// A video in picture in picture came back on its own (its window's close button, the page, or `bringBack`).
    func didLeavePictureInPicture(_ tab: BrowserTab) {
        poppedOut.remove(tab.id)
    }

    /// The video window's "back to tab" button: show the tab, wherever it is. WebKit puts the video back in the
    /// page as soon as the page is on screen.
    func bringBack(_ tab: BrowserTab) {
        poppedOut.remove(tab.id)
        NSApp.activate()
        if let showing = library.window(showing: tab) {
            showing.nsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard library.space(containing: tab) != nil,
              let window = library.owner(of: tab) ?? library.activeWindow else { return }
        window.select(tab)
        window.nsWindow?.makeKeyAndOrderFront(nil)
    }
}
