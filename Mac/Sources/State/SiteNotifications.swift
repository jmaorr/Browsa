import AppKit
import UserNotifications
import BrowserCore
import BrowserEngine

/// Sites' notifications, posted as macOS notifications from Browsa. Clicking one brings its tab forward
/// and tells the page, so the site can open the right chat or email.
///
/// Also the notification centre's delegate, so notifications (sites' and extensions') still show while
/// Browsa is the app in front.
@MainActor
final class SiteNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SiteNotifications()

    weak var library: Library?
    private let center = UNUserNotificationCenter.current()

    func start(library: Library) {
        self.library = library
        center.delegate = self
    }

    /// Asks macOS for permission the first time a site is allowed, so its question comes up straight away
    /// rather than with the site's first message. If notifications are off for Browsa in System Settings,
    /// says so, with a button to go there: macOS never asks twice.
    func requestAuthorization(in window: Browser?) {
        Task {
            if await !systemAllows() { tellOff(in: window, force: true) }
        }
    }

    /// Whether macOS lets Browsa show notifications, asking the first time.
    private func systemAllows() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    /// Whether macOS lets Browsa show notifications. Nil if it hasn't asked yet.
    func isAllowedBySystem() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    /// Asks macOS (it shows its question only the first time). True if allowed.
    func askSystem() async -> Bool { await systemAllows() }

    /// Set once Browsa has said notifications are off, so a busy site doesn't repeat it with every message.
    private var toldOff = false

    private func tellOff(in window: Browser?, force: Bool = false) {
        guard force || !toldOff, let window else { return }
        toldOff = true
        window.showToast("Notifications are off for Browsa in System Settings", actions: [
            ToastAction(title: "Open Settings") { Self.openSystemSettings() }
        ])
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.orriginal.browsa"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts a site's notification. False if macOS won't show it.
    func show(_ notification: WebNotification, from tab: BrowserTab, in window: Browser?) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? notification.host : notification.title
        content.subtitle = notification.title.isEmpty ? "" : notification.host
        content.body = notification.body
        content.threadIdentifier = notification.host
        content.sound = notification.silent ? nil : .default
        content.userInfo = [Key.tab: tab.id.uuidString, Key.id: notification.id]
        let identifier = Self.identifier(tab: tab.id, id: notification.id, tag: notification.tag)
        guard await systemAllows() else {
            tellOff(in: window)
            return false
        }
        if let icon = notification.icon, let attachment = await Self.attachment(for: icon) {
            content.attachments = [attachment]
        }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    func close(tab: UUID, id: String, tag: String?) {
        let identifier = Self.identifier(tab: tab, id: id, tag: tag)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let tabID = (info[Key.tab] as? String).flatMap(UUID.init(uuidString:)),
              let id = info[Key.id] as? String else { return }
        await clicked(tab: tabID, id: id)
    }

    private func clicked(tab tabID: UUID, id: String) {
        guard let library, let tab = library.tab(id: tabID) else { return }
        NSApp.activate()
        if let window = library.window(showing: tab) ?? library.activeWindow {
            window.select(tab)
            window.nsWindow?.makeKeyAndOrderFront(nil)
        }
        if let page = library.existingController(for: tab)?.page {
            (library.engine as? WebNotificationsConfigurable)?.notificationClicked(id, on: page)
        }
    }

    // MARK: Helpers

    private enum Key {
        static let tab = "browsaTab"
        static let id = "browsaNotification"
    }

    /// One per tab and tag, so a newer notification with the same tag replaces the older one, as on the web.
    private static func identifier(tab: UUID, id: String, tag: String?) -> String {
        "site|\(tab.uuidString)|\(tag.map { "tag:" + $0 } ?? id)"
    }

    /// The site's icon as an attachment, if it arrives quickly. Notifications never wait long for it.
    private static func attachment(for url: URL) async -> UNNotificationAttachment? {
        let data: Data
        if url.scheme == "data" {
            guard let d = try? Data(contentsOf: url) else { return nil }
            data = d
        } else {
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (d, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            data = d
        }
        guard data.count < 5_000_000, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notification-\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: file)
    }
}
