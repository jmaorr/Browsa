import Foundation
import Observation
@preconcurrency import Sparkle

/// In-app updates through Sparkle, with its own standard windows.
///
/// Only release builds (tools/release-mac.sh sets `BrowsaUpdates` to YES) run the updater. Xcode
/// runs and install-mac.sh builds leave it off, so they never swap themselves for a release.
@MainActor
@Observable
final class Updates {
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "BrowsaUpdates") as? String == "YES"

    /// False while a check is already running, so the menu item greys out.
    private(set) var canCheck = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        guard Self.isEnabled else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        // Sparkle changes this on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated { self?.canCheck = change.newValue ?? false }
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            withMutation(keyPath: \.installsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }
}
