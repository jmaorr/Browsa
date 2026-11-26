import AppKit
import BrowserCore
import BrowserEngine

/// Downloads beside the page: what happens when a file arrives and when it's finished, and
/// screenshots, which are saved to the same folder and shown in the same list.
extension Library {
    /// Settings › General: open Downloads beside the page when a download finishes. On unless turned off.
    nonisolated static let opensDownloadsKey = "openDownloadsWhenFinished"

    private var opensDownloadsWhenFinished: Bool {
        UserDefaults.standard.object(forKey: Self.opensDownloadsKey) as? Bool ?? true
    }

    /// Lists a download that has just started, and watches it to the end.
    func add(_ download: EngineDownload, from window: Browser?) {
        downloads.insert(download, at: 0)
        (window ?? activeWindow)?.showToast("Downloading \(download.filename)")
        watch(download, from: window)
    }

    private func watch(_ download: EngineDownload, from window: Browser?) {
        withObservationTracking {
            _ = download.status
        } onChange: { [weak self, weak window] in
            Task { @MainActor in
                switch download.status {
                case .running: self?.watch(download, from: window)
                case .finished: self?.reveal(download, in: window)
                case .failed, .cancelled: break
                }
            }
        }
    }

    /// A file is ready: opens Downloads beside the page, so it's there to open or drag somewhere.
    /// Another tool showing in the panel (Notes, say) is left alone, and a toast says the file arrived.
    func reveal(_ download: EngineDownload, in window: Browser?) {
        guard let window = window ?? activeWindow else { return }
        if window.panel == "downloads" { return }
        if opensDownloadsWhenFinished, window.panel == nil {
            window.showPanel("downloads")
        } else {
            window.showToast("Downloaded \(download.filename)",
                             actions: [ToastAction(title: "Show") { [weak window] in window?.showPanel("downloads") }])
        }
    }

    /// Saves a picture of the page as it's showing to the Downloads folder and lists it with the downloads.
    func saveScreenshot(of tab: BrowserTab, in window: Browser) async {
        guard let image = await controller(for: tab).page.snapshot(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            window.showToast("Couldn't take a screenshot of this page")
            return
        }
        let stamp = Date().formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        var file = folder.appending(path: "Browsa Screenshot \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: "Browsa Screenshot \(stamp) \(n).png")
            n += 1
        }
        do {
            try png.write(to: file)
        } catch {
            window.showToast("Couldn't save the screenshot")
            return
        }
        // A private tab's site isn't named in the list.
        let item = EngineDownload(filename: file.lastPathComponent, sourceURL: tab.isPrivate ? nil : tab.url)
        item.fileURL = file
        item.progress = 1
        item.status = .finished
        downloads.insert(item, at: 0)
        reveal(item, in: window)
    }
}
