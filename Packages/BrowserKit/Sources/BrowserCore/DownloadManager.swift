#if os(iOS)
import Foundation
import Observation
import WebKit

/// Saves WKDownloads into Documents/Downloads, which the Files app shows under
/// "On My iPhone > Browsa" (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
@MainActor @Observable
public final class DownloadManager: NSObject {
    public struct Item: Identifiable, Sendable {
        public let id = UUID()
        public var filename: String
        public var sourceURL: URL?
        public var fileURL: URL?
        public var progress: Double = 0
        public var state: State = .running
        public enum State: Sendable, Equatable { case running, finished, failed(String) }
    }

    public private(set) var items: [Item] = []
    /// Bumps when a download finishes, for a haptic and a toast.
    public private(set) var lastFinished: UUID?
    /// True while anything is downloading and for two minutes after, for the toolbar's indicator.
    public private(set) var isIndicatorVisible = false
    /// True for the first few seconds after the last download ends, while the tick shows.
    public private(set) var isShowingFinishTick = false

    /// Overall progress of what's running, 0...1. Nil when nothing is running.
    public var runningProgress: Double? {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    @ObservationIgnored private var byDownload: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var hideIndicatorTask: Task<Void, Never>?

    public static var directory: URL {
        URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    func adopt(_ download: WKDownload) {
        download.delegate = self
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "Download",
                        sourceURL: download.originalRequest?.url)
        items.insert(item, at: 0)
        hideIndicatorTask?.cancel()
        isIndicatorVisible = true
        isShowingFinishTick = false
        byDownload[ObjectIdentifier(download)] = item.id
        let id = item.id
        progressObservations[id] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in self?.update(id) { $0.progress = f } }
        }
    }

    public func remove(_ item: Item) {
        if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
    }

    /// Keeps the indicator handy for a while, since a recent download is often opened next.
    private func scheduleIndicatorHide() {
        guard runningProgress == nil else { return }
        hideIndicatorTask?.cancel()
        isShowingFinishTick = true
        hideIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.isShowingFinishTick = false
            try? await Task.sleep(for: .seconds(115))
            guard !Task.isCancelled else { return }
            self?.isIndicatorVisible = false
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func id(for download: WKDownload) -> UUID? { byDownload[ObjectIdentifier(download)] }

    /// "report.pdf" -> "report 2.pdf" if taken.
    nonisolated static func uniqueDestination(for filename: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appending(path: filename)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.uniqueDestination(for: suggestedFilename, in: dir)
        if let id = id(for: download) {
            update(id) { $0.filename = dest.lastPathComponent; $0.fileURL = dest }
        }
        return dest
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download) else { return }
        update(id) { $0.state = .finished; $0.progress = 1 }
        progressObservations[id] = nil
        lastFinished = id
        scheduleIndicatorHide()
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let id = id(for: download) else { return }
        update(id) { $0.state = .failed(error.localizedDescription) }
        progressObservations[id] = nil
        scheduleIndicatorHide()
    }
}
#endif
