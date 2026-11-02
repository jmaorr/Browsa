#if DEBUG
import Foundation
import BrowserCore

/// Launch arguments for the UI tests: a throwaway state file and a few local tabs, so tests never
/// touch your real tabs or the network. The arguments do nothing in release builds.
///
/// - `--ui-testing <tabs>`: start fresh with that many tabs.
/// - `--posture folded|unfolded`: pick the layout without a real hinge.
enum UITestSupport {
    static var forcedHingeOpen: Bool? {
        guard let i = CommandLine.arguments.firstIndex(of: "--posture"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1] == "unfolded"
    }

    @MainActor static func makeBrowser() -> BrowserState? {
        guard let i = CommandLine.arguments.firstIndex(of: "--ui-testing"), i + 1 < CommandLine.arguments.count,
              let count = Int(CommandLine.arguments[i + 1]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let browser = BrowserState(history: HistoryStore(fileURL: dir.appending(path: "history.json")),
                                   snapshotURL: dir.appending(path: "state.json"),
                                   thumbnailStore: nil)
        browser.settings.blockContent = false
        for n in 1...max(count, 1) {
            let html = "<title>Tab \(n)</title><meta name=viewport content='width=device-width'><h1>Tab \(n)</h1>"
            _ = browser.newTab(url: URL(string: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        }
        return browser
    }
}
#endif
