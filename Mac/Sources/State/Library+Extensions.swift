import AppKit
import BrowserEngine
import Extensibility

/// Adding, updating and removing extensions that don't come from an app: Chrome Web Store and
/// Firefox Add-ons links, and unpacked folders. Browsa keeps them current itself, once a day.
extension Library {
    /// One add, shown on the add sheet before anything runs.
    struct ExtensionPreview: Identifiable {
        var id: String { item.id }
        let item: InstalledExtension
        let manifest: ExtensionManifest
        /// Plain-language lines for the add sheet ("Read and change pages on every site").
        var permissionLines: [String] { manifest.allPermissions.sorted().compactMap(describePermission) }
    }

    nonisolated static let fetch: ExtensionInstaller.Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue("Browsa", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// /usr/bin/ditto ships with macOS and unzips into the app's own container, sandbox and all.
    nonisolated static let unzip: ExtensionInstaller.Unzip = { zip, folder in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path(percentEncoded: false), folder.path(percentEncoded: false)]
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: CocoaError(.fileReadCorruptFile))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// What the engine loads: every enabled catalog extension that has files.
    func extensionFolders() -> [ExtensionFolder] {
        extensionCatalog.enabled.compactMap { item in
            if let bookmark = item.folderBookmark {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else { return nil }
                return ExtensionFolder(id: item.id, url: url)
            }
            return item.folderPath.map { ExtensionFolder(id: item.id, url: URL(filePath: $0)) }
        }
    }

    /// A pasted store link ("chromewebstore.google.com/detail/…/aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    /// or "addons.mozilla.org/…/ublock-origin"): downloads it for the add sheet.
    func previewExtension(link: String) async throws -> ExtensionPreview {
        guard let source = ExtensionSource(link: link) else { throw AddError.notALink }
        let (item, manifest) = try await extensionInstaller.download(source)
        return ExtensionPreview(item: item, manifest: manifest)
    }

    /// An unpacked extension folder the user picked, e.g. one they're building.
    func previewExtension(folder: URL) throws -> ExtensionPreview {
        let manifest = try ExtensionManifest(data: Data(contentsOf: folder.appending(path: "manifest.json")))
        let item = InstalledExtension(source: .folder(path: folder.path(percentEncoded: false)), name: manifest.localizedName(in: folder),
                                      version: manifest.version, folderPath: nil,
                                      folderBookmark: try? folder.bookmarkData(options: .withSecurityScope),
                                      permissions: manifest.allPermissions)
        return ExtensionPreview(item: item, manifest: manifest)
    }

    func install(_ preview: ExtensionPreview) {
        extensionCatalog.upsert(preview.item)
        reloadExtensions()
    }

    func removeExtension(id: String) {
        if let path = extensionCatalog.items.first(where: { $0.id == id })?.folderPath,
           path.hasPrefix(extensionInstaller.root.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(atPath: URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false))
        }
        extensionCatalog.remove(id: id)
        reloadExtensions()
    }

    func setExtension(_ id: String, enabled: Bool) {
        extensionCatalog.setEnabled(enabled, id: id)
        reloadExtensions()
    }

    func approveUpdate(id: String) {
        extensionInstaller.approvePendingUpdate(id: id, in: extensionCatalog)
        reloadExtensions()
    }

    /// Daily, from the app's timer. Updates that ask for nothing new apply quietly; the rest wait in
    /// Settings for a yes.
    func updateExtensions(force: Bool = false) async {
        let outcomes = await extensionInstaller.updateAll(in: extensionCatalog, olderThan: force ? 0 : 20 * 3600)
        if outcomes.values.contains(where: { if case .updated = $0 { true } else { false } }) { reloadExtensions() }
    }

    enum AddError: LocalizedError {
        case notALink
        var errorDescription: String? {
            "Paste a link from the Chrome Web Store or Firefox Add-ons, or an extension's ID."
        }
    }
}
