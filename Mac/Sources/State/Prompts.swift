import Foundation
import BrowserCore
import BrowserEngine

/// Something a page is asking: a JavaScript dialog, a sign-in, or a permission.
/// One shows at a time, as a sheet on the window.
struct Prompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case dialog(EngineDialog)
        case permission(EnginePermission, host: String)
        /// A site wants to hand a link to another app (Zoom, FaceTime, the App Store).
        case openApp(app: String, host: String)
        /// A connected coding agent wants to act on a site for the first time.
        case agent(caller: String, action: String, host: String)
    }

    let id = UUID()
    let kind: Kind
    let tabID: UUID
}

extension Browser {
    /// Queues a prompt and waits for the answer.
    func ask(_ kind: Prompt.Kind, from tab: BrowserTab) async -> EngineDialogResponse {
        // Background tabs don't get to interrupt, the way Safari holds their dialogs.
        guard tab.id == currentTab?.id else { return .cancel }
        return await withCheckedContinuation { cont in
            let prompt = Prompt(kind: kind, tabID: tab.id)
            promptQueue.append((prompt, cont))
            if activePrompt == nil { activePrompt = promptQueue.first?.0 }
        }
    }

    /// Asks on behalf of an agent, whatever tab is showing: agents aren't a page, so they wait for no tab.
    func askForAgent(_ kind: Prompt.Kind) async -> EngineDialogResponse {
        await withCheckedContinuation { cont in
            let prompt = Prompt(kind: kind, tabID: UUID())
            promptQueue.append((prompt, cont))
            if activePrompt == nil { activePrompt = promptQueue.first?.0 }
        }
    }

    func answer(_ response: EngineDialogResponse) {
        guard let current = activePrompt, let i = promptQueue.firstIndex(where: { $0.0.id == current.id }) else { return }
        let (_, cont) = promptQueue.remove(at: i)
        activePrompt = nil
        cont.resume(returning: response)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if activePrompt == nil { activePrompt = promptQueue.first?.0 }
        }
    }

    func cancelPrompts(for tabID: UUID) {
        let mine = promptQueue.filter { $0.0.tabID == tabID }
        promptQueue.removeAll { $0.0.tabID == tabID }
        if activePrompt?.tabID == tabID { activePrompt = nil }
        mine.forEach { $0.1.resume(returning: .cancel) }
        if activePrompt == nil { activePrompt = promptQueue.first?.0 }
    }
}
