import AppKit

/// Synthetic input for the control channel. Events are posted into the app's own event queue, so
/// they need no Accessibility or Input Monitoring permission, never move the real pointer, and
/// work while the window is in the background (you can keep using your Mac).
///
/// Coordinates are window points from the top-left of the window frame, the same frame
/// `screencapture -l` shoots (a screenshot is 2× these on Retina).
@MainActor
enum SpikeInput {
    static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.className.contains("AppKitWindow") && $0.isKeyWindow }
            ?? NSApp.windows.first { $0.isVisible && $0.className.contains("AppKitWindow") }
            ?? NSApp.mainWindow
    }

    /// Menus open right now (context menus included). While one tracks, it reads the app's event
    /// queue itself, so keys must be posted there for arrows, return and escape to reach it.
    static var openMenus: [NSMenu] = []

    private static let menuWatcher = MenuWatcher()

    static func watchMenus() {
        let center = NotificationCenter.default
        center.addObserver(menuWatcher, selector: #selector(MenuWatcher.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(menuWatcher, selector: #selector(MenuWatcher.ended(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    static func closeMenus() {
        for m in openMenus.reversed() { m.cancelTracking() }
    }

    static func point(_ x: Double, _ y: Double, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in window: NSWindow, clicks: Int = 1,
                              flags: NSEvent.ModifierFlags = [], pressure: Float = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: pressure)
    }

    static func click(x: Double, y: Double, count: Int = 1, right: Bool = false, flags: NSEvent.ModifierFlags = []) async {
        guard let window else { return }
        let p = point(x, y, in: window)
        for n in 1...max(1, count) {
            if let down = mouse(right ? .rightMouseDown : .leftMouseDown, p, in: window, clicks: n, flags: flags) { NSApp.postEvent(down, atStart: false) }
            try? await Task.sleep(for: .milliseconds(40))
            if let up = mouse(right ? .rightMouseUp : .leftMouseUp, p, in: window, clicks: n, flags: flags, pressure: 0) { NSApp.postEvent(up, atStart: false) }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    static func hover(x: Double, y: Double) {
        guard let window, let e = mouse(.mouseMoved, point(x, y, in: window), in: window, clicks: 0, pressure: 0) else { return }
        window.acceptsMouseMovedEvents = true
        NSApp.postEvent(e, atStart: false)
    }

    static func drag(from a: (Double, Double), to b: (Double, Double), steps: Int = 12, flags: NSEvent.ModifierFlags = []) async {
        guard let window else { return }
        let start = point(a.0, a.1, in: window)
        if let down = mouse(.leftMouseDown, start, in: window, flags: flags) { NSApp.postEvent(down, atStart: false) }
        let n = max(2, steps)
        for i in 1...n {
            try? await Task.sleep(for: .milliseconds(16))
            let t = Double(i) / Double(n)
            let p = point(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, in: window)
            if let e = mouse(.leftMouseDragged, p, in: window, flags: flags) { NSApp.postEvent(e, atStart: false) }
        }
        try? await Task.sleep(for: .milliseconds(30))
        if let up = mouse(.leftMouseUp, point(b.0, b.1, in: window), in: window, flags: flags, pressure: 0) { NSApp.postEvent(up, atStart: false) }
    }

    /// Scrolls whatever is under the point: lines, positive `dy` scrolls down.
    static func scroll(x: Double, y: Double, dx: Double, dy: Double) {
        guard let window, let content = window.contentView else { return }
        let p = point(x, y, in: window)
        let screen = window.convertPoint(toScreen: p)
        let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        cg.location = flipped
        guard let event = NSEvent(cgEvent: cg) else { return }
        let target = content.superview?.hitTest(content.convert(p, from: nil)) ?? content.hitTest(content.convert(p, from: nil))
        (target ?? content).scrollWheel(with: event)
    }

    // MARK: Keys

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let specialCharacters: [String: Int] = [
        "return": 0x0D, "enter": 0x0D, "tab": 0x09, "delete": 0x7F, "backspace": 0x7F, "escape": 0x1B, "esc": 0x1B,
        "forwarddelete": NSDeleteFunctionKey, "home": NSHomeFunctionKey, "end": NSEndFunctionKey,
        "pageup": NSPageUpFunctionKey, "pagedown": NSPageDownFunctionKey,
        "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey, "down": NSDownArrowFunctionKey, "up": NSUpArrowFunctionKey,
    ]

    static func flags(_ names: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for n in names.map({ $0.lowercased() }) {
            switch n {
            case "cmd", "command": f.insert(.command)
            case "shift": f.insert(.shift)
            case "opt", "option", "alt": f.insert(.option)
            case "ctrl", "control": f.insert(.control)
            default: break
            }
        }
        return f
    }

    /// One key, by name ("k", "return", "left") with modifiers.
    static func key(_ name: String, flags: NSEvent.ModifierFlags = []) {
        guard let window else { return }
        let lower = name.lowercased()
        var chars = name.count == 1 ? name : (specialCharacters[lower].flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? "")
        let ignoring = chars.lowercased()
        if flags.contains(.shift), name.count == 1 { chars = chars.uppercased() }
        let code = keyCodes[lower] ?? 0
        var f = flags
        if name.count > 1, (115...126).contains(code) { f.insert(.function) }
        // Shortcuts go straight to the menu bar: an app in the background doesn't route posted
        // key equivalents through its menus.
        if f.contains(.command), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f,
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                                                          isARepeat: false, keyCode: code),
           NSApp.mainMenu?.performKeyEquivalent(with: e) == true || (!NSApp.isActive && window.performKeyEquivalent(with: e)) {
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) {
                // In the background the app has no key window, so NSApp would drop posted keys.
                // Straight to the window reaches its first responder (a focused field) either way.
                if NSApp.isActive || !openMenus.isEmpty { NSApp.postEvent(e, atStart: false) } else { window.sendEvent(e) }
            }
        }
    }

    /// Text, a key at a time, the way a person types it.
    static func type(_ text: String) async {
        for ch in text {
            let s = String(ch)
            if s == "\n" { key("return") } else {
                let upper = s != s.lowercased()
                key(s, flags: upper ? .shift : [])
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    // MARK: Accessibility tree

    /// The window's accessibility tree, read in-process (no permission needed). Web content is a
    /// single node; use the agent tools (`page_read`) for what's inside a page.
    static var debugAttributes = false

    static func tree(maxDepth: Int = 40) -> [String: Any] {
        guard let window else { return ["error": "No window"] }
        var counter = 0
        return node(window, window: window, depth: 0, maxDepth: maxDepth, counter: &counter) ?? [:]
    }

    struct Found {
        let element: NSObject
        let frame: CGRect
    }

    /// Elements whose label, title, value, identifier or role contains `text`, in tree order.
    static func find(_ text: String, role: String? = nil) -> [Found] {
        guard let window else { return [] }
        var out: [Found] = []
        let needle = text.lowercased()
        walk(window, depth: 0) { el in
            let fields = [label(el), title(el), value(el), identifier(el)].compactMap { $0?.lowercased() }
            let roleOK = role.map { r in (accessibilityRole(el) ?? "").lowercased().contains(r.lowercased()) } ?? true
            if roleOK, needle.isEmpty || fields.contains(where: { $0 == needle }) || fields.contains(where: { $0.contains(needle) }) {
                out.append(Found(element: el, frame: windowFrame(el, in: window)))
            }
        }
        // Exact matches first.
        return out.sorted { a, b in
            let ea = [label(a.element), title(a.element)].contains { $0?.lowercased() == needle }
            let eb = [label(b.element), title(b.element)].contains { $0?.lowercased() == needle }
            return ea && !eb
        }
    }

    static func press(_ found: Found) async -> String {
        if performPress(found.element) { return "pressed" }
        await click(x: found.frame.midX, y: found.frame.midY)
        return "clicked"
    }

    private static func walk(_ el: NSObject, depth: Int, _ visit: (NSObject) -> Void) {
        guard depth < 60 else { return }
        visit(el)
        for c in children(el) { walk(c, depth: depth + 1, visit) }
    }

    private static func node(_ el: NSObject, window: NSWindow, depth: Int, maxDepth: Int, counter: inout Int) -> [String: Any]? {
        counter += 1
        guard counter < 4000 else { return nil }
        var n: [String: Any] = [:]
        if let r = accessibilityRole(el) { n["role"] = r.replacingOccurrences(of: "AX", with: "") }
        if let s = label(el), !s.isEmpty { n["label"] = s }
        if let s = title(el), !s.isEmpty { n["title"] = s }
        if let s = value(el), !s.isEmpty { n["value"] = String(s.prefix(200)) }
        if let s = identifier(el), !s.isEmpty, !s.hasPrefix("_NS:") { n["id"] = s }
        let f = windowFrame(el, in: window)
        if f.width > 0 || f.height > 0 { n["frame"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)] }
        if (attr(el, .enabled) as? Bool) == false { n["disabled"] = true }
        if debugAttributes { n["class"] = el.className; n["attrs"] = el.accessibilityAttributeNames().map(\.rawValue) }
        if depth < maxDepth {
            let kids = children(el).compactMap { node($0, window: window, depth: depth + 1, maxDepth: maxDepth, counter: &counter) }
            // Flatten anonymous groups so the tree stays readable.
            let flat = kids.flatMap { k -> [[String: Any]] in
                let bare = k["label"] == nil && k["title"] == nil && k["value"] == nil && k["id"] == nil
                if bare, (k["role"] as? String) == "Group" || k["role"] == nil, let sub = k["children"] as? [[String: Any]] { return sub }
                return [k]
            }
            if !flat.isEmpty { n["children"] = flat }
        }
        return n
    }

    // SwiftUI's elements answer the older attribute API, not always the protocol, so try both.
    private static func attr(_ el: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
        guard el.accessibilityAttributeNames().contains(name) else { return nil }
        return el.accessibilityAttributeValue(name)
    }

    private static func children(_ el: NSObject) -> [NSObject] {
        if el.className.contains("WKWebView") { return [] }
        if let a = el as? NSAccessibilityProtocol, let kids = a.accessibilityChildren(), !kids.isEmpty {
            return kids.compactMap { $0 as? NSObject }
        }
        return (attr(el, .children) as? [Any] ?? []).compactMap { $0 as? NSObject }
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let s = v as? NSAttributedString { return s.string }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func accessibilityRole(_ el: NSObject) -> String? {
        (el as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? string(attr(el, .role))
    }
    static func label(_ el: NSObject) -> String? {
        nonEmpty((el as? NSAccessibilityProtocol)?.accessibilityLabel()) ?? string(attr(el, .description))
    }
    private static func title(_ el: NSObject) -> String? { nonEmpty((el as? NSAccessibilityProtocol)?.accessibilityTitle()) ?? string(attr(el, .title)) }
    private static func identifier(_ el: NSObject) -> String? { nonEmpty((el as? NSAccessibilityProtocol)?.accessibilityIdentifier()) ?? string(attr(el, .identifier)) }
    private static func value(_ el: NSObject) -> String? { string((el as? NSAccessibilityProtocol)?.accessibilityValue()) ?? string(attr(el, .value)) }
    static func role(_ el: NSObject) -> String? { accessibilityRole(el) }
    private static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

    static func performPress(_ el: NSObject) -> Bool {
        if let a = el as? NSAccessibilityProtocol, a.accessibilityPerformPress() { return true }
        guard el.accessibilityActionNames().contains(.press) else { return false }
        el.accessibilityPerformAction(.press)
        return true
    }

    /// Screen frame (bottom-left origin) to window points (top-left origin).
    static func windowFrame(_ el: NSObject, in window: NSWindow) -> CGRect {
        var f = (el as? NSAccessibilityProtocol)?.accessibilityFrame() ?? .zero
        if f == .zero, let p = (attr(el, .position) as? NSValue)?.pointValue, let size = (attr(el, .size) as? NSValue)?.sizeValue {
            // The attribute API gives a top-left origin on the primary screen.
            let primary = NSScreen.screens.first?.frame.height ?? 0
            f = CGRect(x: p.x, y: primary - p.y - size.height, width: size.width, height: size.height)
        }
        guard f != .zero else { return .zero }
        return CGRect(x: f.minX - window.frame.minX, y: window.frame.maxY - f.maxY, width: f.width, height: f.height)
    }
}

/// Menus post their tracking notifications on the main thread.
@MainActor
private final class MenuWatcher: NSObject {
    @objc func began(_ note: Notification) {
        if let m = note.object as? NSMenu { SpikeInput.openMenus.append(m) }
    }

    @objc func ended(_ note: Notification) {
        SpikeInput.openMenus.removeAll { $0 === (note.object as? NSMenu) }
    }
}
