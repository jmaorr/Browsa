import AppKit
import Observation
@preconcurrency import Sparkle

/// In-app updates through Sparkle, with its own standard windows (and our own wording when a
/// check can't reach browsa.app, see `UpdateUserDriver`).
///
/// Only release builds (tools/release-mac.sh sets `BrowsaUpdates` to YES) run the updater. Xcode
/// runs and install-mac.sh builds leave it off, so they never swap themselves for a release.
@MainActor
@Observable
final class Updates {
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "BrowsaUpdates") as? String == "YES"

    /// False while a check is already running, so the menu item greys out.
    private(set) var canCheck = false

    @ObservationIgnored private let updater: SPUUpdater?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        guard Self.isEnabled else { updater = nil; return }
        // What SPUStandardUpdaterController does, with our own user driver so a failed check can
        // say what went wrong.
        let userDriver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: nil)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            NSLog("Browsa: the updater didn't start: %@", String(describing: error))
        }
        canCheck = updater.canCheckForUpdates
        // Sparkle changes this on the main thread.
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated { self?.canCheck = change.newValue ?? false }
        }
    }

    func checkForUpdates() { updater?.checkForUpdates() }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return updater?.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.checksAutomatically) { updater?.automaticallyChecksForUpdates = newValue }
        }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return updater?.automaticallyDownloadsUpdates ?? false }
        set {
            withMutation(keyPath: \.installsAutomatically) { updater?.automaticallyDownloadsUpdates = newValue }
        }
    }
}

/// Sparkle's standard windows, except a check or download that couldn't reach browsa.app.
/// Sparkle's own alert for that only says "An error occurred in retrieving update information",
/// which leaves people on a work network that blocks the site guessing.
final class UpdateUserDriver: SPUStandardUserDriver {
    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard let failure = UpdateNetworkFailure(error) else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }
        NSLog("Browsa: update check failed (%@): %@", String(describing: failure), String(describing: error))
        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
        acknowledgement()
    }
}

/// Why Sparkle couldn't download the appcast or an update, when it's the network's doing.
enum UpdateNetworkFailure: Equatable, CustomStringConvertible {
    /// The Mac isn't connected.
    case offline
    /// Something between the Mac and browsa.app refused the connection: a work or school filter,
    /// a captive portal, or a proxy swapping in its own certificate.
    case blocked
    /// browsa.app answered with a server error.
    case serverDown
    /// Anything else on the way there, like a timeout.
    case unreachable

    /// Only Sparkle's download errors (the appcast or an update file) count. Others keep
    /// Sparkle's own alert.
    init?(_ error: any Error) {
        let top = error as NSError
        // 2001 is SUDownloadError.
        guard top.domain == SUSparkleErrorDomain, top.code == 2001 else { return nil }
        // Sparkle wraps the real failure in NSUnderlyingErrorKey, sometimes more than once.
        var chain: [NSError] = []
        var next: NSError? = top
        while let current = next, chain.count < 8 {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let urlError = chain.first(where: { $0.domain == NSURLErrorDomain }) {
            switch URLError.Code(rawValue: urlError.code) {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                self = .offline
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
                 .userAuthenticationRequired, .appTransportSecurityRequiresSecureConnection:
                self = .blocked
            default:
                self = .unreachable
            }
            return
        }
        // A bad HTTP status comes as Sparkle's own error, "A network error occurred while
        // downloading <url>. Forbidden (403)", with the code only in the text.
        if let status = chain.lazy.compactMap({ Self.httpStatus(in: $0.localizedDescription) }).first {
            switch status {
            case 401, 403, 407, 451: self = .blocked
            case 500...599: self = .serverDown
            default: self = .unreachable
            }
            return
        }
        return nil
    }

    static func httpStatus(in text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("A network error occurred while downloading"), text.hasSuffix(")"),
              let open = text.lastIndex(of: "(") else { return nil }
        let digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard digits.count == 3 else { return nil }
        return Int(digits)
    }

    var title: String {
        switch self {
        case .offline: "You're offline"
        case .blocked: "Your network blocked the update"
        case .serverDown: "Updates aren't available right now"
        case .unreachable: "Browsa couldn't reach browsa.app"
        }
    }

    var message: String {
        switch self {
        case .offline:
            "Browsa couldn't check for updates because this Mac isn't connected to the internet. Try again once you're back online."
        case .blocked:
            "Browsa couldn't reach browsa.app on this network. Some work and school networks block new websites. Try another network, or ask your IT team to allow browsa.app."
        case .serverDown:
            "browsa.app didn't respond properly. Try again in a little while."
        case .unreachable:
            "Check your internet connection or VPN, then try again."
        }
    }

    var description: String {
        switch self {
        case .offline: "offline"
        case .blocked: "blocked"
        case .serverDown: "server error"
        case .unreachable: "unreachable"
        }
    }
}
