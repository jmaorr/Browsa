import AppKit
import BrowserEngine

/// Which extensions sit in the address pill, and the per-page state of their toolbar actions.
extension Library {
    /// Extensions that have a toolbar action, in the order they loaded.
    var actionExtensions: [EngineExtension] { extensions.filter(\.hasAction) }

    /// Pinned to the address pill. Until the user pins or unpins anything, the first password manager is.
    var pinnedExtensions: [EngineExtension] {
        _ = extensionPinsRevision
        let pinned = Preferences.pinnedExtensions ?? defaultPins()
        return actionExtensions.filter { pinned.contains($0.id) }
    }

    func isPinned(_ ext: EngineExtension) -> Bool { pinnedExtensions.contains { $0.id == ext.id } }

    func setPinned(_ ext: EngineExtension, _ pinned: Bool) {
        var ids = Set(Preferences.pinnedExtensions ?? defaultPins())
        if pinned { ids.insert(ext.id) } else { ids.remove(ext.id) }
        Preferences.pinnedExtensions = ids
        extensionPinsRevision += 1
    }

    private func defaultPins() -> Set<String> {
        let managers = ["1password", "bitwarden", "lastpass", "dashlane", "proton pass", "keeper", "nordpass", "roboform", "enpass"]
        let first = actionExtensions.first { ext in managers.contains { ext.name.lowercased().contains($0) } }
        return first.map { [$0.id] } ?? []
    }

    /// The extension's action as it stands for `page`. Reading `extensionActionsRevision` makes views
    /// that call this redraw when an extension updates its badge or icon.
    func actionState(_ ext: EngineExtension, for page: (any EnginePage)?) -> EngineActionState? {
        _ = extensionActionsRevision
        return engine.extensionActionState(extensionID: ext.id, for: page)
    }

    func extensionActionsDidChange() { extensionActionsRevision += 1 }

}
