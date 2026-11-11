#if os(macOS)
import AppKit
import WebKit
import UserNotifications
import BrowserEngine

/// Chrome APIs WebKit doesn't have, done for real by Browsa: the compat script's stand-ins send
/// native messages to these names, answered in-process.
///
/// - `browsa.notifications`: `chrome.notifications.create/clear` as macOS notifications.
/// - `browsa.sidepanel`: `chrome.sidePanel.open` and `setPanelBehavior` show the extension's page in
///   Browsa's right panel.
/// - `browsa.downloads`: `chrome.downloads.download` saves through the app's Downloads list.
@available(macOS 15.4, *)
@MainActor
enum ExtensionBridges {
    static let notifications = "browsa.notifications"
    static let sidePanel = "browsa.sidepanel"
    static let downloads = "browsa.downloads"
    static let names: Set<String> = [notifications, sidePanel, downloads]

    static func handle(_ name: String, message: Any, extensionID: String, displayName: String,
                       host: (any EngineExtensionHost)?, reply: @escaping (Any?, (any Error)?) -> Void) {
        let body = message as? [String: Any] ?? [:]
        switch name {
        case notifications: notify(body, extensionID: extensionID, from: displayName, reply: reply)
        case sidePanel: panel(body, extensionID: extensionID, host: host, reply: reply)
        case downloads: download(body, extensionID: extensionID, host: host, reply: reply)
        default: reply(nil, error("Unknown bridge \(name)"))
        }
    }

    // MARK: Notifications

    private static var asked = false

    private static func notify(_ body: [String: Any], extensionID: String, from name: String, reply: @escaping (Any?, (any Error)?) -> Void) {
        let id = "\(extensionID)|\(body["id"] as? String ?? UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        switch body["action"] as? String {
        case "clear":
            center.removeDeliveredNotifications(withIdentifiers: [id])
            center.removePendingNotificationRequests(withIdentifiers: [id])
            reply(true, nil)
        case "create":
            let content = UNMutableNotificationContent()
            content.title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            content.body = body["message"] as? String ?? ""
            content.subtitle = content.title == name ? "" : name
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            Task { @MainActor in
                if !asked {
                    asked = true
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                }
                do {
                    try await center.add(request)
                    reply(true, nil)
                } catch {
                    reply(nil, error)
                }
            }
        default:
            reply(nil, error("Unknown notifications action"))
        }
    }

    // MARK: Side panel

    static func opensPanelOnAction(_ extensionID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "sidePanelOnAction." + extensionID)
    }

    private static func panel(_ body: [String: Any], extensionID: String, host: (any EngineExtensionHost)?,
                              reply: @escaping (Any?, (any Error)?) -> Void) {
        switch body["action"] as? String {
        case "open":
            let shown = host?.showExtensionPanel(extensionID: extensionID) ?? false
            shown ? reply(true, nil) : reply(nil, error("This extension has no side panel"))
        case "behavior":
            UserDefaults.standard.set(body["openPanelOnActionClick"] as? Bool ?? false, forKey: "sidePanelOnAction." + extensionID)
            reply(true, nil)
        case "getBehavior":
            reply(["openPanelOnActionClick": opensPanelOnAction(extensionID)], nil)
        default:
            reply(nil, error("Unknown sidePanel action"))
        }
    }

    // MARK: Downloads

    private static var nextDownloadID = 1

    private static func download(_ body: [String: Any], extensionID: String, host: (any EngineExtensionHost)?,
                                 reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let raw = body["url"] as? String, let url = URL(string: raw),
              ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else {
            reply(nil, error("downloads.download needs an http(s), data: or blob: URL"))
            return
        }
        // WebKit downloads it like a link (cookies, progress, the Downloads list), from the tab in front.
        // Never through a private window: that would use its cookies on the extension's behalf.
        let window = host?.extensionWindows.first { !$0.isPrivate }
        guard let page = window?.activePage as? WebKitPage, let engine = page.engine else {
            reply(nil, error("Open a regular (not private) tab first: Browsa downloads through the tab in front"))
            return
        }
        nextDownloadID += 1
        let downloadID = nextDownloadID
        page.webView.startDownload(using: URLRequest(url: url)) { download in
            engine.downloads.adopt(download, from: page)
        }
        reply(downloadID, nil)
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Browsa.Extensions", code: 3, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
#endif
