import AppKit
import WebKit

/// Grabs a web page as an image, offscreen, at any size: for the reel's page layers. WebKit won't
/// paint pages in SpikeBrowsa's window while it sits behind other windows, but a web view in its own
/// offscreen window snapshots fine.
@MainActor
enum ReelCapture {
    private static var holders: [NSWindow] = []

    static func snapshot(url: URL, size: CGSize, settle: Double = 1.6) async throws -> NSImage {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        // Light, like the rest of the reel, whatever the Mac is set to.
        web.appearance = NSAppearance(named: .aqua)
        // Offscreen but real: a borderless window far off any screen keeps WebKit painting.
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        holders.append(window)
        defer { window.orderOut(nil); holders.removeAll { $0 === window } }

        let loaded = LoadWaiter()
        web.navigationDelegate = loaded
        web.load(URLRequest(url: url))
        try await loaded.wait()
        try await Task.sleep(for: .seconds(settle))
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(origin: .zero, size: size)
        shot.snapshotWidth = NSNumber(value: Double(size.width) * 2)
        return try await web.takeSnapshot(configuration: shot)
    }

    static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
