import AppKit
import BrowserCore

/// Closing a tab, or quitting, in the middle of a call would just drop you from it: ask first. A tab is in a call while
/// its page has the camera or microphone on (`PageState.isCapturingMedia`).
@MainActor
enum CallGuards {
    static func install(in library: Library) {
        library.closeGuard = { [weak library] tab in
            guard let library else { return true }
            return confirmLeaving(tabsInCall(in: library).filter { $0.id == tab.id }, quitting: false)
        }
    }

    static func tabsInCall(in library: Library) -> [BrowserTab] {
        library.allTabs.filter { library.existingController(for: $0)?.page.state.isCapturingMedia == true }
    }

    /// True to go ahead.
    static func confirmLeaving(_ tabs: [BrowserTab], quitting: Bool) -> Bool {
        guard let tab = tabs.first else { return true }
        let alert = NSAlert()
        let name = tab.title.isEmpty ? (tab.url?.host() ?? "a call") : tab.title
        alert.messageText = quitting ? "You're on a call. Quit Browsa?" : "Leave the call?"
        alert.informativeText = quitting
            ? "\(name) is using your microphone or camera. Quitting ends the call."
            : "\(name) is using your microphone or camera. Closing the tab ends the call."
        alert.addButton(withTitle: quitting ? "Quit" : "Leave Call")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
