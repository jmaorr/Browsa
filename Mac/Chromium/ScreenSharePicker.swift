import AppKit
import ScreenCaptureKit

/// What a call tab shares when a site asks to present: a whole display or one window, picked in
/// Browsa's own sheet (CEF's embedded mode has no picker of its own). Returns a Chromium desktop
/// media ID ("screen:<display>:0" or "window:<window>:0"), or nil when cancelled.
@MainActor
enum ScreenSharePicker {
    struct Source { let title: String; let id: String }

    static func sources() async -> [Source] {
        // Listing windows needs Screen Recording permission; without it, displays still work (macOS
        // asks for the permission when capture starts).
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return NSScreen.screens.enumerated().map { i, screen in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                return Source(title: "Entire screen" + (NSScreen.screens.count > 1 ? " \(i + 1) (\(screen.localizedName))" : ""), id: "screen:\(id):0")
            }
        }
        var list = content.displays.enumerated().map { i, d in
            Source(title: "Entire screen" + (content.displays.count > 1 ? " \(i + 1) (\(d.width)×\(d.height))" : ""), id: "screen:\(d.displayID):0")
        }
        let own = Bundle.main.bundleIdentifier
        for w in content.windows where w.isOnScreen && w.windowLayer == 0 && (w.frame.width > 120 && w.frame.height > 80) {
            guard let app = w.owningApplication, app.bundleIdentifier != own else { continue }
            let title = (w.title?.isEmpty == false) ? "\(app.applicationName) — \(w.title!)" : app.applicationName
            list.append(Source(title: title, id: "window:\(w.windowID):0"))
        }
        return list
    }

    static func pick(host: String, in window: NSWindow?) async -> String? {
        // Chromium only checks Screen Recording permission; it never asks. Browsa asks macOS (the first
        // time this shows the system prompt), and macOS applies a new grant only after a relaunch.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Browsa needs Screen Recording permission to share your screen"
            alert.informativeText = "Turn on Browsa in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Browsa and share again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            let r: NSApplication.ModalResponse
            if let window { r = await alert.beginSheetModal(for: window) } else { r = alert.runModal() }
            if r == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
        let all = await sources()
        guard !all.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Share your screen with \(host)?"
        alert.informativeText = "Choose what to share. Others on the call will see it until you stop sharing."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for s in all { popup.addItem(withTitle: s.title) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return all[popup.indexOfSelectedItem].id
    }
}
