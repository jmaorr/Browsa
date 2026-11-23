import AppKit
import UserNotifications
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
    /// rather than with the site's first message.
    func requestAuthorization() {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func show(_ notification: WebNotification, from tab: BrowserTab) {
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? notification.host : notification.title
        content.subtitle = notification.title.isEmpty ? "" : notification.host
        content.body = notification.body
        content.threadIdentifier = notification.host
        content.sound = notification.silent ? nil : .default
        content.userInfo = [Key.tab: tab.id.uuidString, Key.id: notification.id]
        let identifier = Self.identifier(tab: tab.id, id: notification.id, tag: notification.tag)
        Task {
            if let icon = notification.icon, let attachment = await Self.attachment(for: icon) {
                content.attachments = [attachment]
            }
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
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
