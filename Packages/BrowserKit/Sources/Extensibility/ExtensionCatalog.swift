import Foundation
import CryptoKit

/// One extension the user added, wherever it came from.
public struct InstalledExtension: Codable, Identifiable, Hashable, Sendable {
    /// `source.key`: stable across versions and launches.
    public var id: String { source.key }
    public var source: ExtensionSource
    public var name: String
    public var version: String
    public var isEnabled: Bool
    /// The unpacked extension the engine loads. Store installs live in Browsa's own folder;
    /// "Load unpacked" points at the user's folder.
    public var folderPath: String?
    /// A security-scoped bookmark for a user-picked folder, so the sandboxed app can reopen it.
    public var folderBookmark: Data?
    /// What the running version was allowed, for comparing with an update.
    public var permissions: Set<String>
    public var addedAt: Date
    public var checkedAt: Date?
    /// A newer version that asks for more than this one, waiting for the user to say yes.
    public var pendingUpdate: PendingUpdate?

    public struct PendingUpdate: Codable, Hashable, Sendable {
        public var version: String
        public var folderPath: String
        public var newPermissions: Set<String>
    }

    public init(source: ExtensionSource, name: String, version: String, isEnabled: Bool = true,
                folderPath: String?, folderBookmark: Data? = nil, permissions: Set<String>, addedAt: Date = .now) {
        self.source = source
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.permissions = permissions
        self.addedAt = addedAt
    }
}

/// The extensions the user added, saved as JSON. Safari extensions from installed apps aren't listed
/// unless the user turned one off; they're found fresh at each launch.
@MainActor
public final class ExtensionCatalog {
    public private(set) var items: [InstalledExtension] = []
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.iso.decode([InstalledExtension].self, from: data) {
            items = saved
        }
    }

    public subscript(id: String) -> InstalledExtension? { items.first { $0.id == id } }

    public var enabled: [InstalledExtension] { items.filter(\.isEnabled) }

    public func upsert(_ item: InstalledExtension) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        save()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(_ on: Bool, id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isEnabled = on
        save()
    }

    public func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(items).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Installing and updating

/// Downloads store extensions, unpacks them, makes Chrome ones WebKit-ready, and keeps them current.
///
/// Network and unzip are passed in, so this runs in tests and in the sandboxed app alike (the app
/// unzips with `/usr/bin/ditto`).
@MainActor
public final class ExtensionInstaller {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Unzip = @Sendable (_ zip: URL, _ into: URL) async throws -> Void

    public enum Failure: LocalizedError, Equatable {
        case notAStoreSource
        case notFound(String)
        case hashMismatch
        case noManifest

        public var errorDescription: String? {
            switch self {
            case .notAStoreSource: "That extension doesn't come from a store."
            case .notFound(let id): "The store has no extension \(id)."
            case .hashMismatch: "The download didn't match what the store said it would be."
            case .noManifest: "The package has no manifest.json."
            }
        }
    }

    /// What an update check found.
    public enum UpdateOutcome: Equatable, Sendable {
        case upToDate
        case updated(from: String, to: String)
        /// Newer, but it asks for more; it waits in `pendingUpdate`.
        case needsApproval(version: String, newPermissions: Set<String>)
    }

    /// Unpacked extensions go in `root/<source key>/<version>/`.
    public let root: URL
    private let fetch: Fetch
    private let unzip: Unzip

    public init(root: URL, fetch: @escaping Fetch, unzip: @escaping Unzip) {
        self.root = root
        self.fetch = fetch
        self.unzip = unzip
    }

    /// Downloads and unpacks the newest version. Nothing is added to the catalog: the caller shows
    /// the add sheet with the result's permissions first.
    public func download(_ source: ExtensionSource) async throws -> (InstalledExtension, ExtensionManifest) {
        let release = try await latestRelease(source)
        let folder = try await unpack(release, source: source)
        let manifest = try ExtensionManifest(data: Data(contentsOf: folder.appending(path: "manifest.json")))
        let item = InstalledExtension(source: source, name: manifest.localizedName(in: folder), version: manifest.version,
                                      folderPath: folder.path(percentEncoded: false), permissions: manifest.allPermissions)
        return (item, manifest)
    }

    /// Checks one store extension and updates it if that needs no new permissions.
    public func update(_ item: InstalledExtension, in catalog: ExtensionCatalog) async throws -> UpdateOutcome {
        guard item.source.isFromStore else { throw Failure.notAStoreSource }
        var item = item
        item.checkedAt = .now
        let release = try await latestRelease(item.source)
        guard isVersion(release.version, newerThan: item.version) else {
            catalog.upsert(item)
            return .upToDate
        }
        if let pending = item.pendingUpdate, pending.version == release.version {
            return .needsApproval(version: pending.version, newPermissions: pending.newPermissions)
        }
        let folder = try await unpack(release, source: item.source)
        let manifest = try ExtensionManifest(data: Data(contentsOf: folder.appending(path: "manifest.json")))
        let added = manifest.allPermissions.subtracting(item.permissions)
        if !added.isEmpty {
            item.pendingUpdate = .init(version: manifest.version, folderPath: folder.path(percentEncoded: false), newPermissions: added)
            catalog.upsert(item)
            return .needsApproval(version: manifest.version, newPermissions: added)
        }
        let old = item.version
        let oldFolder = item.folderPath
        item.version = manifest.version
        item.folderPath = folder.path(percentEncoded: false)
        item.pendingUpdate = nil
        catalog.upsert(item)
        if let oldFolder, oldFolder != folder.path(percentEncoded: false) { try? FileManager.default.removeItem(atPath: oldFolder) }
        return .updated(from: old, to: manifest.version)
    }

    /// The user said yes to an update's new permissions.
    public func approvePendingUpdate(id: String, in catalog: ExtensionCatalog) {
        guard var item = catalog[id], let pending = item.pendingUpdate else { return }
        let oldFolder = item.folderPath
        item.version = pending.version
        item.folderPath = pending.folderPath
        item.permissions.formUnion(pending.newPermissions)
        item.pendingUpdate = nil
        catalog.upsert(item)
        if let oldFolder, oldFolder != pending.folderPath { try? FileManager.default.removeItem(atPath: oldFolder) }
    }

    /// Every enabled store extension not checked in the last `interval`. Chrome ones are asked about
    /// in one request. Returns what changed, by extension id; failures are skipped until next time.
    public func updateAll(in catalog: ExtensionCatalog, olderThan interval: TimeInterval = 20 * 3600) async -> [String: UpdateOutcome] {
        var results: [String: UpdateOutcome] = [:]
        let due = catalog.enabled.filter { $0.source.isFromStore && ($0.checkedAt.map { -$0.timeIntervalSinceNow > interval } ?? true) }
        for item in due {
            if let outcome = try? await update(item, in: catalog), outcome != .upToDate { results[item.id] = outcome }
        }
        return results
    }

    // MARK: Steps

    func latestRelease(_ source: ExtensionSource) async throws -> StoreRelease {
        switch source {
        case .chromeWebStore(let id):
            let data = try await fetch(ChromeWebStore.updateCheckURL(ids: [id]))
            guard let release = UpdateManifestParser.parse(data).first(where: { $0.id == id }) else { throw Failure.notFound(id) }
            return release
        case .firefoxAddons(let slug):
            let data = try await fetch(FirefoxAddons.detailsURL(slug: slug))
            return try FirefoxAddons.release(from: data)
        case .safariApp, .folder:
            throw Failure.notAStoreSource
        }
    }

    func unpack(_ release: StoreRelease, source: ExtensionSource) async throws -> URL {
        let data = try await fetch(release.downloadURL)
        if let expected = release.sha256?.lowercased() {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure.hashMismatch }
        }
        let zip = try CRX.zipPayload(of: data)
        let fm = FileManager.default
        let safeKey = source.key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
        let folder = root.appending(path: safeKey).appending(path: release.version)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zipFile = fm.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        try zip.write(to: zipFile)
        defer { try? fm.removeItem(at: zipFile) }
        try await unzip(zipFile, folder)
        guard fm.fileExists(atPath: folder.appending(path: "manifest.json").path(percentEncoded: false)) else { throw Failure.noManifest }
        return folder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
