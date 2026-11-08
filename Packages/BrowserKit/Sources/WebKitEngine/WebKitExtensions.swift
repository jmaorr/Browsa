#if os(macOS)
import AppKit
import WebKit
import BrowserEngine

/// Safari web extensions the user already has (inside apps like 1Password for Safari), run by
/// WebKit's WKWebExtensionController. Native messages go to the Chrome-style host the
/// extension's app installs (see `NativeHost`).
///
/// Spike: every extension gets all the permissions it asks for, plus every site.
@available(macOS 15.4, *)
@MainActor
final class WebKitExtensions: NSObject, WKWebExtensionControllerDelegate {
    let controller = WKWebExtensionController()
    weak var host: (any EngineExtensionHost)?
    private(set) var loaded: [EngineExtension] = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var windows: [UUID: ExtensionWindow] = [:]
    /// Extensions loaded from a folder rather than an app. They get no native messaging.
    private var unpacked: Set<String> = []
    /// Where the popup of the button being clicked should appear.
    private weak var popupAnchor: NSView?

    static let extensionPoint = "com.apple.Safari.web-extension"

    override init() {
        super.init()
        controller.delegate = self
    }

    // MARK: Finding and loading

    /// Safari web extension bundles inside the apps in /Applications and ~/Applications.
    static func installedBundles() -> (found: [URL], problems: [String]) {
        let fm = FileManager.default
        var found: [URL] = [], problems: [String] = []
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for root in roots {
            let apps: [URL]
            do {
                apps = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            } catch {
                if root.path() != roots[1].path() { problems.append("can't list \(root.path()): \(error.localizedDescription)") }
                continue
            }
            for app in apps {
                let plugins = app.appending(path: "Contents/PlugIns")
                for appex in (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
                where appex.pathExtension == "appex" {
                    let info = Bundle(url: appex)?.infoDictionary?["NSExtension"] as? [String: Any]
                    if info?["NSExtensionPointIdentifier"] as? String == extensionPoint { found.append(appex) }
                }
            }
        }
        return (found, problems)
    }

    func loadInstalled(folders: [ExtensionFolder] = [], includeApps: Bool = true) async -> [String] {
        var (bundles, problems) = includeApps ? Self.installedBundles() : ([], [])
        let env = ProcessInfo.processInfo.environment
        if env["BROWSA_ONLY_EXT_FOLDERS"] != nil { bundles = [] }
        // Unpacked extensions: Browsa's store installs, folders the user picked, and (for testing)
        // BROWSA_EXT_FOLDERS, a colon-separated list of paths.
        var unpackedFolders = folders
        for path in (env["BROWSA_EXT_FOLDERS"] ?? "").split(separator: ":").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            unpackedFolders.append(ExtensionFolder(id: "unpacked." + url.lastPathComponent, url: url))
        }
        for folder in unpackedFolders {
            let id = folder.id
            guard contexts[id] == nil else { continue }
            do {
                let ext = try await WKWebExtension(resourceBaseURL: folder.url)
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                context.isInspectable = true
                grantEverything(context)
                try controller.load(context)
                contexts[id] = context
                unpacked.insert(id)
                loaded.append(describe(ext, context: context, id: id))
                problems += (ext.errors + context.errors).map { "\(id): \($0.localizedDescription)" }
            } catch {
                problems.append("\(id): \(error)")
            }
        }
        for url in bundles {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, contexts[id] == nil else { continue }
            do {
                let ext = try await WKWebExtension(appExtensionBundle: bundle)
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                context.isInspectable = true
                grantEverything(context)
                try controller.load(context)
                contexts[id] = context
                loaded.append(describe(ext, context: context, id: id))
                problems += (ext.errors + context.errors).map { "\(id): \($0.localizedDescription)" }
                engineLog.info("extension loaded: \(id, privacy: .public)")
            } catch {
                problems.append("\(id): \(error.localizedDescription)")
            }
        }
        for p in problems { engineLog.error("extension: \(p, privacy: .public)") }
        // Tabs that were open before the extensions arrived.
        if let any = contexts.values.first {
            for window in currentWindows() {
                controller.didOpenWindow(window)
                window.tabs(for: any).forEach(controller.didOpenTab)
            }
        }
        if let focused = currentWindows().first { controller.didFocusWindow(focused) }
        return problems
    }

    /// The toolbar and Settings entry for a loaded extension, with its side panel page if it has one.
    private func describe(_ ext: WKWebExtension, context: WKWebExtensionContext, id: String) -> EngineExtension {
        let icon = ext.icon(for: CGSize(width: 32, height: 32))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let manifest = ext.manifest
        let panelPath = ((manifest["side_panel"] as? [String: Any])?["default_path"] as? String)
            ?? ((manifest["sidebar_action"] as? [String: Any])?["default_panel"] as? String)
        let panelURL = panelPath.map { context.baseURL.appending(path: $0.hasPrefix("/") ? String($0.dropFirst()) : $0) }
        return EngineExtension(id: id, name: ext.displayName ?? id, version: ext.version ?? "",
                               icon: icon, hasAction: context.action(for: nil) != nil, panelURL: panelURL)
    }

    private func grantEverything(_ context: WKWebExtensionContext) {
        let ext = context.webExtension
        for p in ext.requestedPermissions.union(ext.optionalPermissions) {
            context.setPermissionStatus(.grantedExplicitly, for: p)
        }
        for m in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: m) }
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
    }

    func unloadAll() {
        for c in contexts.values { try? controller.unload(c) }
        contexts = [:]
        loaded = []
    }

    // MARK: Actions

    func performAction(extensionID: String, for page: WebKitPage?, anchor: NSView?) {
        guard let context = contexts[extensionID] else { return }
        popupAnchor = anchor
        let action = context.action(for: page)
        print("[ext] nativeMessaging status=\(context.permissionStatus(for: .nativeMessaging).rawValue) granted=\(context.grantedPermissions.keys.map(\.rawValue).sorted())")
        print("[ext] perform \(extensionID): presentsPopup=\(action?.presentsPopup as Any) label=\(action?.label ?? "-") enabled=\(action?.isEnabled as Any) errors=\(context.errors.map { e in "\(e.localizedDescription) \((e as NSError).userInfo)" }) tab=\(page.map { context.webExtension.displayName ?? "" + ($0.webView.url?.absoluteString ?? "") } ?? "nil")")
        context.performAction(for: page)
    }

    #if DEBUG
    /// Spike diagnostics: runs JavaScript in an extension's background page (WebKit private API).
    func debugBackground(extensionID: String, _ body: String) async -> String {
        guard let context = contexts[extensionID] else { return "no context" }
        let sel = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: sel), let web = context.perform(sel)?.takeUnretainedValue() as? WKWebView else {
            return "no background web view"
        }
        do {
            let r = try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            return "url=\(web.url?.absoluteString ?? "-") result=\(String(describing: r))"
        } catch {
            return "url=\(web.url?.absoluteString ?? "-") error=\(error)"
        }
    }
    #endif

    /// Extension pages (popups aside) only load in web views made from their extension's configuration.
    func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme == "webkit-extension" else { return nil }
        return contexts.values.first { $0.baseURL.host() == url.host() }?.webViewConfiguration
    }

    // MARK: Tabs and windows

    func window(_ id: UUID) -> ExtensionWindow {
        if let w = windows[id] { return w }
        let w = ExtensionWindow(id: id, extensions: self)
        windows[id] = w
        return w
    }

    func currentWindows() -> [ExtensionWindow] {
        let infos = host?.extensionWindows ?? []
        windows = windows.filter { id, _ in infos.contains { $0.id == id } }
        return infos.map { window($0.id) }
    }

    func info(for id: UUID) -> EngineWindowInfo? { host?.extensionWindows.first { $0.id == id } }

    func windowInfo(containing page: WebKitPage) -> EngineWindowInfo? {
        host?.extensionWindows.first { $0.pages.contains { $0 === page } }
    }

    func pageOpened(_ page: WebKitPage) { if !contexts.isEmpty { controller.didOpenTab(page) } }
    func pageClosed(_ page: WebKitPage) { if !contexts.isEmpty { controller.didCloseTab(page, windowIsClosing: false) } }

    func pageActivated(_ page: WebKitPage) {
        guard !contexts.isEmpty else { return }
        if let info = windowInfo(containing: page) { controller.didFocusWindow(window(info.id)) }
        controller.didActivateTab(page, previousActiveTab: nil)
    }

    func pageChanged(_ page: WebKitPage) {
        guard !contexts.isEmpty else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: page)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        currentWindows()
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        currentWindows().first
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let windowID = (configuration.window as? ExtensionWindow)?.id
        let page = host?.openExtensionTab(url: configuration.url, windowID: windowID, active: configuration.shouldBeActive)
        completionHandler(page as? WebKitPage, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler(urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
    }

    // Native messaging. WebKit's own route (to the handler inside the extension's app extension) answers
    // "Native messaging is not supported" for extensions from other apps, so Browsa runs the
    // Chrome-style native messaging host the app installs instead, the way Chrome does.

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        print("[ext] sendMessage app=\(applicationIdentifier ?? "nil") \(NativeHost.describe(message))")
        if unpacked.contains(extensionContext.uniqueIdentifier) {
            replyHandler(nil, NativeHost.missing(applicationIdentifier))
            return
        }
        guard let host = NativeHost(name: applicationIdentifier, origin: extensionContext.baseURL) else {
            replyHandler(nil, NativeHost.missing(applicationIdentifier))
            return
        }
        var replied = false
        host.onMessage = { reply in
            guard !replied else { return }
            replied = true
            print("[ext] sendMessage reply \(NativeHost.describe(reply))")
            replyHandler(reply, nil)
            host.stop()
        }
        host.onExit = { status, stderr in
            print("[ext] native host exited \(status) stderr=\(stderr.prefix(400))")
            if !replied { replied = true; replyHandler(nil, NativeHost.exited(status)) }
        }
        host.start()
        host.send(message)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        print("[ext] connect app=\(port.applicationIdentifier ?? "nil")")
        if unpacked.contains(extensionContext.uniqueIdentifier) {
            completionHandler(NativeHost.missing(port.applicationIdentifier))
            return
        }
        guard let host = NativeHost(name: port.applicationIdentifier, origin: extensionContext.baseURL) else {
            completionHandler(NativeHost.missing(port.applicationIdentifier))
            return
        }
        host.onMessage = { reply in
            print("[ext] port <- host \(NativeHost.describe(reply))")
            port.sendMessage(reply) { error in if let error { print("[ext] port send failed \(error)") } }
        }
        host.onExit = { status, stderr in
            print("[ext] native host exited \(status) stderr=\(stderr.prefix(400))")
            port.disconnect(throwing: NativeHost.exited(status))
        }
        port.messageHandler = { message, error in
            if let message {
                print("[ext] port -> host \(NativeHost.describe(message))")
                host.send(message)
            }
        }
        port.disconnectHandler = { _ in host.stop() }
        host.start()
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        print("[ext] presentActionPopup popover=\(action.popupPopover != nil) anchor=\(popupAnchor != nil)")
        guard let popover = action.popupPopover,
              let anchor = popupAnchor ?? NSApp.keyWindow?.contentView else {
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }
}

/// A Chrome-style native messaging host: a helper app that installs a manifest naming itself, and
/// talks over stdin/stdout with each message as a 32-bit length then JSON.
@MainActor
final class NativeHost {
    var onMessage: (Any) -> Void = { _ in }
    var onExit: (Int32, String) -> Void = { _, _ in }
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data()

    /// Spike: hosts are found by name in Chrome's manifest folder, with 1Password's built in when
    /// the sandbox hides that folder.
    init?(name: String?, origin: URL) {
        guard let name, let path = Self.executable(for: name) else { return nil }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [origin.absoluteString]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    static func executable(for name: String) -> String? {
        let manifest = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/\(name).json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["path"] as? String {
            return path
        }
        if name == "com.1password.1password" {
            return "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"
        }
        return nil
    }

    func start() {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                let stderr = String(data: self.errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                self.onExit(status, stderr)
            }
        }
        do { try process.run() } catch {
            print("[ext] native host failed to start: \(error)")
            onExit(-1, error.localizedDescription)
        }
    }

    func send(_ message: Any) {
        guard process.isRunning, JSONSerialization.isValidJSONObject(message) || message is String,
              let json = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        var length = UInt32(json.count).littleEndian
        try? input.fileHandleForWriting.write(contentsOf: Data(bytes: &length, count: 4) + json)
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeFirst(4 + length)
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) { onMessage(message) }
        }
    }

    static func describe(_ message: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: message).prefix(300).description }
        return String(text.prefix(300))
    }

    static func missing(_ name: String?) -> NSError {
        NSError(domain: "Browsa", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native messaging host named \(name ?? "nil")"])
    }

    static func exited(_ status: Int32) -> NSError {
        NSError(domain: "Browsa", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native messaging host exited (\(status))"])
    }
}

/// A Browsa window, for extensions.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let id: UUID
    private weak var extensions: WebKitExtensions?

    init(id: UUID, extensions: WebKitExtensions) {
        self.id = id
        self.extensions = extensions
    }

    private var info: EngineWindowInfo? { extensions?.info(for: id) }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        info?.pages.compactMap { $0 as? WebKitPage } ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { info?.activePage as? WebKitPage }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { info?.isPrivate ?? false }
    func frame(for context: WKWebExtensionContext) -> CGRect { info?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        extensions?.host?.focusExtensionWindow(id)
        completionHandler(nil)
    }
}

/// A Browsa tab, for extensions: its page.
@available(macOS 15.4, *)
extension WebKitPage: WKWebExtensionTab {
    private var extensions: WebKitExtensions? { engine?.webExtensions }
    private var windowInfo: EngineWindowInfo? { extensions?.windowInfo(containing: self) }

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let info = windowInfo else { return nil }
        return extensions?.window(info.id)
    }

    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        windowInfo?.pages.firstIndex { $0 === self } ?? 0
    }

    public func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    public func title(for context: WKWebExtensionContext) -> String? { webView.title }
    public func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    public func isSelected(for context: WKWebExtensionContext) -> Bool { windowInfo?.activePage === self }
    public func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

    public func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        extensions?.host?.activateExtensionTab(self)
        completionHandler(nil)
    }

    public func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        extensions?.host?.closeExtensionTab(self)
        completionHandler(nil)
    }
}
#endif
