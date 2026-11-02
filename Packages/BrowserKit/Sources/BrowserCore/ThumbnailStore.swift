import Foundation

/// Tab pictures on disk, so the gallery has them after a relaunch. They live in Caches: the system
/// may clear them, and a tab just falls back to its icon. Private tabs never come here.
public struct ThumbnailStore: Sendable {
    public let directory: URL

    public init(directory: URL = URL.cachesDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).jpg") }

    public func save(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: id), options: .atomic)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Reads the pictures for `ids` and deletes the rest, which belong to tabs that have gone.
    public func loadAll(keeping ids: Set<UUID>) -> [UUID: Data] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [UUID: Data] = [:]
        for file in files {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), ids.contains(id) {
                out[id] = try? Data(contentsOf: file)
            } else {
                try? fm.removeItem(at: file)
            }
        }
        return out
    }
}
