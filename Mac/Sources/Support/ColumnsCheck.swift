#if DEBUG
import AppKit

/// Debug only: with BROWSA_COLUMNS_CHECK=<folder>, opens the right panel and drags its divider (and the
/// sidebar's) with AppKit mouse events, logging the columns' frames as they go. Writes columns.txt and
/// window images, then quits.
@MainActor
struct ColumnsCheck {
    let directory: URL
    let delegate: AppDelegate

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var waited = 0.0
        while delegate.browser?.nsWindow == nil, waited < 20 { await pause(0.5); waited += 0.5 }
        guard let browser = delegate.browser, let window = browser.nsWindow else { note("no window"); exit(1) }
        browser.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Web_browser")!)
        await pause(3)
        browser.showPanel("notes")
        await pause(1.5)
        guard let split = find(window.contentView) else { note("no split view"); exit(1) }
        note("start: \(frames(split)) panelWidth=\(Int(browser.panelWidth)) panel=\(browser.panel ?? "nil")")
        save(window, "0-open")
        for (i, v) in split.subviews.enumerated() {
            let h = v.constraintsAffectingLayout(for: .horizontal).map { "\($0)" }.filter { !$0.contains("NSAutoresizingMaskLayoutConstraint") }
            note("column \(i) \(type(of: v)) fitting=\(v.fittingSize) intrinsic=\(v.intrinsicContentSize) constraints: \(h.prefix(8).joined(separator: " || "))")
        }

        // The panel's divider: drag left 120 pt (wider), then right 200 pt (narrower), then far right (past its minimum).
        for (name, dx) in [("wider", -120.0), ("wider-again", -60.0), ("narrower", 200.0), ("past-minimum", 400.0)] {
            guard split.subviews.count >= 3 else { break }
            let x = split.subviews[2].frame.minX - split.dividerThickness / 2
            await drag(window, split, from: NSPoint(x: x, y: split.bounds.midY), by: dx, label: name)
            await pause(0.8)
            note("after \(name): \(frames(split)) panelWidth=\(Int(browser.panelWidth)) panel=\(browser.panel ?? "nil")")
            save(window, "1-\(name)")
            if browser.panel == nil { browser.showPanel("notes"); await pause(1) }
        }
        // Cmd-S: the sidebar hides and comes back, with the panel open, plain and right after a drag.
        for round in ["panel open", "after a drag", "quick double"] {
            if round == "after a drag", split.subviews.count >= 3 {
                let x = split.subviews[2].frame.minX - split.dividerThickness / 2
                await drag(window, split, from: NSPoint(x: x, y: split.bounds.midY), by: -40, label: "pre-toggle drag")
                await pause(0.5)
            }
            browser.toggleSidebar()
            if round == "quick double" { await pause(0.1); browser.toggleSidebar(); await pause(0.1); browser.toggleSidebar() }
            var trace: [String] = []
            for _ in 0..<8 { await pause(0.1); trace.append("\(Int(split.subviews[0].frame.width))\(split.isSubviewCollapsed(split.subviews[0]) ? "c" : "")") }
            note("toggle (\(round)): docked=\(browser.isSidebarDocked) sidebar widths over 0.8 s: \(trace.joined(separator: " ")) -> \(frames(split))")
            browser.toggleSidebar()
            await pause(1)
            note("toggle back (\(round)): docked=\(browser.isSidebarDocked) -> \(frames(split))")
        }
        // The sidebar's divider still works.
        let sx = split.subviews[0].frame.maxX + split.dividerThickness / 2
        await drag(window, split, from: NSPoint(x: sx, y: split.bounds.midY), by: 60, label: "sidebar")
        await pause(0.8)
        note("after sidebar drag: \(frames(split)) sidebarWidth=\(Int(browser.sidebarWidth))")
        save(window, "2-sidebar")
        exit(0)
    }

    /// Mouse down at `start` (split view coordinates), drags in steps, mouse up. NSSplitView tracks the
    /// drag inside mouseDown by pulling the queued events, so they're queued first.
    private func drag(_ window: NSWindow, _ split: NSSplitView, from start: NSPoint, by dx: Double, label: String) async {
        let p0 = split.convert(start, to: nil)
        let steps = 12
        var t = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            t += 0.016
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        for i in 1...steps {
            let p = NSPoint(x: p0.x + dx * Double(i) / Double(steps), y: p0.y)
            if let e = event(.leftMouseDragged, p) { NSApp.postEvent(e, atStart: false) }
        }
        if let up = event(.leftMouseUp, NSPoint(x: p0.x + dx, y: p0.y)) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, p0) {
            note("\(label): mouse down at x=\(Int(start.x)), hit \(split.hitTest(start).map { "\(type(of: $0))" } ?? "nil")")
            window.sendEvent(down)
        }
    }

    private func frames(_ split: NSSplitView) -> String {
        split.subviews.enumerated().map { i, v in "[\(i)] x=\(Int(v.frame.minX)) w=\(Int(v.frame.width))\(split.isSubviewCollapsed(v) ? " collapsed" : "")" }
            .joined(separator: " ") + " total=\(Int(split.bounds.width))"
    }

    private func find(_ view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let s = view as? ColumnsSplitView { return s }
        for sub in view.subviews { if let f = find(sub) { return f } }
        return nil
    }

    private func save(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("[columns] \(line)\n".utf8))
    }

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
}
#endif
