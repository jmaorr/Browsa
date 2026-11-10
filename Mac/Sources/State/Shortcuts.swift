import AppKit
import SwiftUI

// MARK: - Keys

/// One shortcut: a key and its modifiers, as saved and as shown ("⌥⌘↓").
struct KeyCombo: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    /// A character ("t", "[", ".") or a named key ("tab", "left", "down", "return", "delete", "space").
    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The key pressed, read the same way whatever the keyboard layout's shift does to it, so
    /// ⇧⌘] is "]" with shift rather than "}".
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if let named = Self.namedKeyCodes[event.keyCode] {
            key = named
        } else if let c = event.characters(byApplyingModifiers: [])?.lowercased(), let ch = c.first,
                  c.count == 1, !ch.isWhitespace, !ch.isNewline, ch.unicodeScalars.first.map({ $0.value < 0xF700 }) == true {
            key = String(ch)
        } else {
            return nil
        }
        modifiers = m
    }

    private static let namedKeyCodes: [UInt16: String] = [
        48: "tab", 123: "left", 124: "right", 125: "down", 126: "up",
        36: "return", 76: "return", 51: "delete", 49: "space", 53: "escape",
    ]

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let glyphs = ["tab": "⇥", "left": "←", "right": "→", "up": "↑", "down": "↓",
                      "return": "↩", "delete": "⌫", "space": "Space", "escape": "⎋"]
        return s + (glyphs[key] ?? key.uppercased())
    }

    var keyboardShortcut: KeyboardShortcut {
        let named: [String: KeyEquivalent] = [
            "tab": .tab, "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
            "return": .return, "delete": .delete, "space": .space, "escape": .escape,
        ]
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(named[key] ?? KeyEquivalent(Character(key)), modifiers: m)
    }

    /// Kept for macOS and editing everywhere, or fixed in Browsa: never offered to an action.
    static let reserved: [KeyCombo: String] = {
        var r: [KeyCombo: String] = [:]
        for (k, name) in [("q", "Quit"), ("h", "Hide"), ("m", "Minimise"), (",", "Settings"), ("c", "Copy"),
                          ("v", "Paste"), ("x", "Cut"), ("z", "Undo"), ("a", "Select All"), ("`", "Cycle Windows"),
                          ("=", "Zoom In"), ("-", "Zoom Out"), ("0", "Actual Size"), ("tab", "Switch Apps")] {
            r[KeyCombo(k)] = name
        }
        r[KeyCombo("z", [.command, .shift])] = "Redo"
        r[KeyCombo("=", [.command, .shift])] = "Zoom In"
        r[KeyCombo("tab", .control)] = "Next Tab"
        r[KeyCombo("tab", [.control, .shift])] = "Previous Tab"
        for n in 1...9 {
            r[KeyCombo("\(n)")] = n == 9 ? "Last Tab" : "Tab \(n)"
            r[KeyCombo("\(n)", .control)] = "Space \(n)"
        }
        return r
    }()
}

// MARK: - Actions

/// A preset is a whole set of keys: Arc's (Browsa's own), Chrome's or Safari's.
enum ShortcutPreset: String, CaseIterable, Identifiable, Sendable {
    case browsa, chrome, safari
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browsa: "Browsa"
        case .chrome: "Chrome"
        case .safari: "Safari"
        }
    }
    var summary: String {
        switch self {
        case .browsa: "Arc's keys: ⌘D pins a tab, ⌘S shows the sidebar, ⌥⌘↓ moves down your tabs."
        case .chrome: "Chrome's keys: ⌘D adds a favourite, ⌥⌘→ moves between tabs, ⇧⌘R reloads without the cache."
        case .safari: "Safari's keys: ⌘D adds a favourite, ⇧⌘L shows the sidebar, ⌥⌘L opens Downloads."
        }
    }
}

/// Everything in the menus that can have its keys changed. The raw values are the command ids
/// ⌘K uses too, so its rows can show the same keys.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    // Tabs and windows
    case newTab = "new-tab", openLocation = "open-location", commands = "commands"
    case newWindow = "new-window", privateTab = "private"
    case close, reopen, closeOthers = "close-others", clearToday = "clear-today"
    case nextTab = "next-tab", previousTab = "previous-tab"
    case pin, favourite, archive
    // Spaces and window
    case nextSpace = "next-space", previousSpace = "previous-space"
    case sidebar, panel, notes, downloads
    // Page
    case back, forward, reload, hardReload = "hard-reload", stop
    case find, findNext = "find-next", findPrevious = "find-previous"
    case copyLink = "copy-link", copyMarkdown = "copy-markdown"
    case reader, inspector

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case tabs = "Tabs", spaces = "Spaces and Window", page = "Page"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .newTab, .openLocation, .commands, .newWindow, .privateTab, .close, .reopen, .closeOthers,
             .clearToday, .nextTab, .previousTab, .pin, .favourite, .archive: .tabs
        case .nextSpace, .previousSpace, .sidebar, .panel, .notes, .downloads: .spaces
        default: .page
        }
    }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .openLocation: "Open Location"
        case .commands: "Commands and Tools"
        case .newWindow: "New Window"
        case .privateTab: "New Private Tab"
        case .close: "Close Tab"
        case .reopen: "Reopen Closed Tab"
        case .closeOthers: "Close Other Tabs"
        case .clearToday: "Clear Today's Tabs"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .pin: "Pin Tab"
        case .favourite: "Add to Favourites"
        case .archive: "Archived Tabs"
        case .nextSpace: "Next Space"
        case .previousSpace: "Previous Space"
        case .sidebar: "Show or Hide Sidebar"
        case .panel: "Show or Hide Panel"
        case .notes: "Notes"
        case .downloads: "Downloads"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload Page"
        case .hardReload: "Reload Without Cache"
        case .stop: "Stop"
        case .find: "Find"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .copyLink: "Copy Link"
        case .copyMarkdown: "Copy Link as Markdown"
        case .reader: "Show or Hide Reader"
        case .inspector: "Web Inspector"
        }
    }

    /// The keys a preset gives this action. The first is the one the menu shows; any others work too.
    func keys(in preset: ShortcutPreset) -> [KeyCombo] {
        let cmd: KeyCombo.Modifiers = .command
        let shiftCmd: KeyCombo.Modifiers = [.shift, .command]
        let optCmd: KeyCombo.Modifiers = [.option, .command]
        let ctrlCmd: KeyCombo.Modifiers = [.control, .command]
        func k(_ key: String, _ m: KeyCombo.Modifiers = cmd) -> KeyCombo { KeyCombo(key, m) }
        switch (self, preset) {
        case (.newTab, _): return [k("t")]
        case (.openLocation, _): return [k("l")]
        case (.commands, _): return [k("k")]
        case (.newWindow, _): return [k("n")]
        case (.privateTab, _): return [k("n", shiftCmd)]
        case (.close, _): return [k("w")]
        case (.reopen, _): return [k("t", shiftCmd)]
        case (.closeOthers, _): return [k("w", optCmd)]
        case (.clearToday, _): return [k("k", shiftCmd)]
        case (.nextTab, .browsa): return [k("down", optCmd), k("]", shiftCmd)]
        case (.nextTab, .chrome): return [k("right", optCmd), k("]", shiftCmd)]
        case (.nextTab, .safari): return [k("]", shiftCmd)]
        case (.previousTab, .browsa): return [k("up", optCmd), k("[", shiftCmd)]
        case (.previousTab, .chrome): return [k("left", optCmd), k("[", shiftCmd)]
        case (.previousTab, .safari): return [k("[", shiftCmd)]
        case (.pin, .browsa): return [k("d")]
        case (.pin, _): return [k("d", shiftCmd)]
        case (.favourite, .browsa): return [k("d", shiftCmd)]
        case (.favourite, _): return [k("d")]
        case (.archive, _): return [k("y")]
        case (.nextSpace, .chrome): return [k("right", ctrlCmd)]
        case (.nextSpace, _): return [k("right", optCmd)]
        case (.previousSpace, .chrome): return [k("left", ctrlCmd)]
        case (.previousSpace, _): return [k("left", optCmd)]
        case (.sidebar, .safari): return [k("l", shiftCmd)]
        case (.sidebar, _): return [k("s")]
        case (.panel, _): return [k("s", optCmd)]
        case (.notes, _): return [k("m", shiftCmd)]
        case (.downloads, .safari): return [k("l", optCmd)]
        case (.downloads, _): return [k("j", shiftCmd)]
        case (.back, _): return [k("[")]
        case (.forward, _): return [k("]")]
        case (.reload, _): return [k("r")]
        case (.hardReload, .chrome): return [k("r", shiftCmd)]
        case (.hardReload, _): return [k("r", optCmd)]
        case (.stop, _): return [k(".")]
        case (.find, _): return [k("f")]
        case (.findNext, _): return [k("g")]
        case (.findPrevious, _): return [k("g", shiftCmd)]
        case (.copyLink, _): return [k("c", shiftCmd)]
        case (.copyMarkdown, _): return [k("c", [.option, .shift, .command])]
        case (.reader, .chrome): return [k("r", optCmd)]
        case (.reader, _): return [k("r", shiftCmd)]
        case (.inspector, _): return [k("i", optCmd)]
        }
    }
}

// MARK: - Store

/// The keys in use: a preset, plus whatever you've changed in Settings › Shortcuts. The menus,
/// the key monitor, ⌘K rows and tooltips all read from here.
@MainActor @Observable
final class Shortcuts {
    static let shared = Shortcuts()

    private(set) var preset: ShortcutPreset
    /// Your changes, by action. An empty list means no shortcut.
    private(set) var overrides: [ShortcutAction: [KeyCombo]]

    private static let presetKey = "shortcutPreset"
    private static let overridesKey = "shortcutOverrides"

    private init() {
        let d = UserDefaults.standard
        preset = d.string(forKey: Self.presetKey).flatMap(ShortcutPreset.init(rawValue:)) ?? .browsa
        var loaded: [ShortcutAction: [KeyCombo]] = [:]
        if let data = d.data(forKey: Self.overridesKey),
           let raw = try? JSONDecoder().decode([String: [KeyCombo]].self, from: data) {
            for (id, keys) in raw { if let a = ShortcutAction(rawValue: id) { loaded[a] = keys } }
        }
        overrides = loaded
    }

    func keys(for action: ShortcutAction) -> [KeyCombo] {
        overrides[action] ?? action.keys(in: preset)
    }

    /// For the menu: the first key, if there is one.
    func shortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        keys(for: action).first?.keyboardShortcut
    }

    func display(_ action: ShortcutAction) -> String? {
        keys(for: action).first?.display
    }

    /// "Hide Sidebar (⌘S)", or just the title when the action has no key.
    func help(_ title: String, _ action: ShortcutAction) -> String {
        display(action).map { "\(title) (\($0))" } ?? title
    }

    func isCustom(_ action: ShortcutAction) -> Bool {
        guard let o = overrides[action] else { return false }
        return o != action.keys(in: preset)
    }

    var hasChanges: Bool { ShortcutAction.allCases.contains(where: isCustom) }

    /// The action this key press belongs to.
    func action(for event: NSEvent) -> ShortcutAction? {
        guard let combo = KeyCombo(event: event) else { return nil }
        return ShortcutAction.allCases.first { keys(for: $0).contains(combo) }
    }

    func matches(_ action: ShortcutAction, _ event: NSEvent) -> Bool {
        guard let combo = KeyCombo(event: event) else { return false }
        return keys(for: action).contains(combo)
    }

    /// True when the key press is one of the action's extra keys, which the menu doesn't show.
    func isAlternate(_ event: NSEvent) -> ShortcutAction? {
        guard let combo = KeyCombo(event: event) else { return nil }
        return ShortcutAction.allCases.first { keys(for: $0).dropFirst().contains(combo) }
    }

    func usePreset(_ p: ShortcutPreset) {
        preset = p
        overrides = [:]
        save()
    }

    /// Gives the action this key (or none). A key can only do one thing, so it's taken off any
    /// action that had it; that action is returned so Settings can say so.
    @discardableResult
    func set(_ action: ShortcutAction, to combo: KeyCombo?) -> ShortcutAction? {
        var taken: ShortcutAction?
        if let combo {
            for other in ShortcutAction.allCases where other != action {
                let ks = keys(for: other)
                if ks.contains(combo) {
                    overrides[other] = ks.filter { $0 != combo }
                    taken = other
                }
            }
        }
        overrides[action] = combo.map { [$0] } ?? []
        tidy()
        save()
        return taken
    }

    func reset(_ action: ShortcutAction) {
        // The preset key comes back, so it's taken off whatever action was given it since.
        for combo in action.keys(in: preset) {
            for other in ShortcutAction.allCases where other != action && overrides[other]?.contains(combo) == true {
                overrides[other]?.removeAll { $0 == combo }
            }
        }
        overrides[action] = nil
        tidy()
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    /// Drops overrides that ended up the same as the preset.
    private func tidy() {
        for (a, ks) in overrides where ks == a.keys(in: preset) { overrides[a] = nil }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(preset.rawValue, forKey: Self.presetKey)
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        d.set(try? JSONEncoder().encode(raw), forKey: Self.overridesKey)
    }
}
