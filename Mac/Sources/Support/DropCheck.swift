#if DEBUG
import AppKit
import BrowserEngine

/// Debug only: with BROWSA_DROP_CHECK=<folder>, opens a page with a drop zone and drops a file on it
/// through AppKit's dragging-destination calls (what a drag from Finder ends in), then reads what the
/// page received. Also lists which views under the point accept drags, front to back.
@MainActor
struct DropCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser, let window = browser.nsWindow else { note("no window"); exit(1) }
        let html = """
        <body style="margin:0"><div id=z style="position:fixed;inset:0;background:#eef">drop here</div><script>
        window.got = []; const z = document.getElementById('z');
        ['dragenter','dragover','drop'].forEach(t => z.addEventListener(t, e => { e.preventDefault();
          window.got.push(t + (e.dataTransfer ? ':' + [...e.dataTransfer.files].map(f => f.name + '/' + f.size).join(',') : '')); }));
        </script></body>
        """
        let file = directory.appending(path: "drop-test.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try? rep?.representation(using: .png, properties: [:])?.write(to: file)
        note("test file: \((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) ?? "missing") bytes")
        browser.newTab(url: URL(string: "https://example.com")!)
        await pause(3)
        guard let page = browser.currentController?.page else { note("no page"); exit(1) }
        page.loadHTML(html, baseURL: URL(string: "https://example.com"))
        await pause(2)

        guard let web = find(window.contentView, WKWebViewClass) else { note("no web view"); exit(1) }
        let point = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        var chain: [String] = []
        var v = window.contentView?.superview?.hitTest(point)
        while let view = v {
            let types = view.registeredDraggedTypes.map(\.rawValue)
            chain.append("\(type(of: view))\(types.isEmpty ? "" : " [accepts \(types.count): \(types.prefix(3).joined(separator: ","))…]")")
            v = view.superview
        }
        note("views under the page centre (hit view up to the window): \(chain.joined(separator: " < "))")

        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let info = FakeDrag(pasteboard: pasteboard, location: point, window: window)
        let entered = web.draggingEntered(info)
        var updates: [UInt] = []
        for _ in 0..<5 { updates.append(web.draggingUpdated(info).rawValue); await pause(0.2) }
        let updated = NSDragOperation(rawValue: updates.last ?? 0)
        note("draggingUpdated over 1 s: \(updates)")
        _ = web.prepareForDragOperation(info)
        let performed = web.performDragOperation(info)
        web.concludeDragOperation(info)
        await pause(2)
        let got = (try? await page.evaluate("return JSON.stringify(window.got)", inWorld: "page")).map { "\($0)" } ?? "nil"
        note("web view: entered=\(entered.rawValue) updated=\(updated.rawValue) performed=\(performed); page got \(got)")
        exit(0)
    }

    private let WKWebViewClass: AnyClass = NSClassFromString("WKWebView")!

    private func find(_ view: NSView?, _ cls: AnyClass) -> NSView? {
        guard let view else { return nil }
        if view.isKind(of: cls), !view.isHiddenOrHasHiddenAncestor { return view }
        for s in view.subviews { if let f = find(s, cls) { return f } }
        return nil
    }

    private func note(_ line: String) { FileHandle.standardError.write(Data("[drop] \(line)\n".utf8)) }
    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}

/// Enough of NSDraggingInfo for a destination view to read a drop.
@MainActor
private final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    weak var window: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingLocation = location; self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
