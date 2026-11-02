#if os(iOS)
import Foundation
import WebKit

/// Something a page is asking the user: a JavaScript dialog, a permission, or a login.
/// WebKit's delegate awaits the answer; the app shows one at a time as a native alert.
public struct WebPrompt: Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case alert
        case confirm
        case textInput(defaultText: String)
        case permission(SitePermission)
        case credentials(realm: String?)
    }

    public let id = UUID()
    public let kind: Kind
    /// The site asking, e.g. "example.com". Always shown so a page can't impersonate the browser.
    public let host: String
    public let message: String
    let tabID: UUID
}

public enum WebPromptResponse: Equatable, Sendable {
    case ok
    case cancel
    case text(String)
    case credentials(user: String, password: String)
}

public enum SitePermission: String, Codable, Sendable {
    case camera, microphone, cameraAndMicrophone, motion

    public var title: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .cameraAndMicrophone: "use your camera and microphone"
        case .motion: "access motion and orientation"
        }
    }
}

extension BrowserState {
    /// Queues a prompt and waits for the user's answer.
    func ask(_ kind: WebPrompt.Kind, host: String, message: String, from tab: BrowserTab) async -> WebPromptResponse {
        // Pages in background tabs don't get to interrupt: dialogs there get the default answer,
        // the way Safari suspends them until you switch back.
        guard tab.id == currentTab?.id else { return .cancel }
        // A page that loops alert() would otherwise trap the user.
        let now = Date()
        promptLog[tab.id] = (promptLog[tab.id] ?? []).filter { now.timeIntervalSince($0) < 10 } + [now]
        if case .permission = kind {} else if case .credentials = kind {} else if (promptLog[tab.id]?.count ?? 0) > 5 {
            return .cancel
        }
        return await withCheckedContinuation { cont in
            let prompt = WebPrompt(kind: kind, host: host, message: message, tabID: tab.id)
            promptQueue.append((prompt, cont))
            if activePrompt == nil { showNextPrompt() }
        }
    }

    /// Called by the alert UI.
    public func answer(_ response: WebPromptResponse) {
        guard let current = activePrompt, let i = promptQueue.firstIndex(where: { $0.0.id == current.id }) else { return }
        let (_, cont) = promptQueue.remove(at: i)
        activePrompt = nil
        cont.resume(returning: response)
        // Let the dismiss animation finish before the next alert slides in.
        Task { try? await Task.sleep(for: .milliseconds(250)); showNextPrompt() }
    }

    /// Answers every pending prompt from a tab with Cancel (tab closed or navigated away).
    func cancelPrompts(for tabID: UUID) {
        let mine = promptQueue.filter { $0.0.tabID == tabID }
        promptQueue.removeAll { $0.0.tabID == tabID }
        if activePrompt?.tabID == tabID { activePrompt = nil }
        mine.forEach { $0.1.resume(returning: .cancel) }
        if activePrompt == nil { showNextPrompt() }
    }

    private func showNextPrompt() {
        guard activePrompt == nil else { return }
        activePrompt = promptQueue.first?.0
    }

    // MARK: Permissions

    /// A remembered answer, or asks and remembers it.
    func decide(_ permission: SitePermission, host: String, tab: BrowserTab) async -> WKPermissionDecision {
        if let saved = settings.sitePermissions[host]?[permission.rawValue] { return saved ? .grant : .deny }
        let answer = await ask(.permission(permission), host: host,
                               message: "Allow \(host) to \(permission.title)?", from: tab)
        guard tab.id == currentTab?.id || answer != .cancel else { return .deny }
        let granted = answer == .ok
        settings.sitePermissions[host, default: [:]][permission.rawValue] = granted
        return granted ? .grant : .deny
    }

    public func forgetPermissions(for host: String) {
        settings.sitePermissions[host] = nil
    }
}
#endif
