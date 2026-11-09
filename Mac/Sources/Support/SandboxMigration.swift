import Foundation
import BrowserCore

/// Browsa left the App Sandbox (Radar needs to see other processes and project folders). A
/// sandboxed app keeps everything in ~/Library/Containers/<bundle id>; once it isn't sandboxed it
/// reads ~/Library instead, so on the first launch out of the sandbox this copies the old data
/// across: tabs, history, notes, extensions, site data and sign-ins, and settings.
///
/// It copies rather than moves, and never touches the container, which stays as a backup. It runs
/// once, before anything opens a store, and only when there's nothing at the new place yet.
enum SandboxMigration {
    static func runIfNeeded() {
        guard !AppFolders.isSandboxed, let id = Bundle.main.bundleIdentifier else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let old = library.appending(path: "Containers/\(id)/Data/Library", directoryHint: .isDirectory)
        let support = AppFolders.support
        let marker = support.appending(path: ".migrated-from-sandbox")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: marker.path) else { return }
        // Already has data of its own: leave it alone rather than mix the two.
        if fm.fileExists(atPath: support.appending(path: "Browser/state.json").path) {
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            try? Data("skipped: \(Date())\n".utf8).write(to: marker)
            return
        }
        log("copying \(old.path)")

        // Browsa's own files: Application Support's Browser, Filters and the extension copies.
        let oldSupport = old.appending(path: "Application Support", directoryHint: .isDirectory)
        for name in ["Browser", "Filters", "Extensions (WebKit)"] {
            copy(oldSupport.appending(path: name), to: support.appending(path: name))
        }
        // WebKit's: site data, extension storage and compiled content rules, then cookies (sign-ins),
        // which WebKit keeps in HTTPStorages.
        copy(old.appending(path: "WebKit"), to: library.appending(path: "WebKit/\(id)"), mergeInto: true)
        copy(old.appending(path: "HTTPStorages/\(id)"), to: library.appending(path: "HTTPStorages/\(id)"))

        // Saved paths that point into the container (store-installed extensions) now point here.
        rewritePaths(in: support.appending(path: "Browser"), from: oldSupport.path, to: support.path)

        // Settings, through cfprefsd so it picks them up.
        if let prefs = NSDictionary(contentsOf: old.appending(path: "Preferences/\(id).plist")) as? [String: Any] {
            let existing = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
            UserDefaults.standard.setPersistentDomain(prefs.merging(existing) { _, new in new }, forName: id)
        }

        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? Data("copied from \(old.path) at \(Date())\n".utf8).write(to: marker)
        log("done")
    }

    /// Copies a file or folder. With `mergeInto`, a folder that's already there (WebKit may have
    /// made an empty one) gets the missing items instead of being skipped.
    private static func copy(_ from: URL, to: URL, mergeInto: Bool = false) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: to.path) {
            do { try fm.copyItem(at: from, to: to) } catch { log("couldn't copy \(from.lastPathComponent): \(error)") }
            return
        }
        guard mergeInto, let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        for item in items { copy(item, to: to.appending(path: item.lastPathComponent), mergeInto: true) }
    }

    private static func rewritePaths(in folder: URL, from: String, to: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        // Paths are JSON strings, so slashes may be escaped.
        let pairs = [(from, to), (from.replacingOccurrences(of: "/", with: "\\/"), to.replacingOccurrences(of: "/", with: "\\/"))]
        for file in files where file.pathExtension == "json" {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let before = text
            for (a, b) in pairs { text = text.replacingOccurrences(of: a, with: b) }
            if text != before { try? text.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    private static func log(_ line: String) { NSLog("[migration] %@", line) }
}
