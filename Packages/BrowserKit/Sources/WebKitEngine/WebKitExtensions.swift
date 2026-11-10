#if os(macOS)
import AppKit
import WebKit
import CryptoKit
import BrowserEngine
import BrowserCore

/// Web extensions run by WebKit's WKWebExtensionController: Safari extensions inside the user's
/// apps, and unpacked folders (store installs and ones the user picked).
///
/// Extensions get the permissions they ask for: the user saw them on the add sheet, or, for
/// Safari extensions, when they installed the app. Per-site prompts come later.
@available(macOS 15.4, *)
@MainActor
final class WebKitExtensions: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController = {
        // An extension's background has no window, so WebKit treats its process as inactive and can
        // pause it mid-task. Extension web views are never paused (see also startKeepAlive).
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.webViewConfiguration?.preferences.inactiveSchedulingPolicy = .none
        return WKWebExtensionController(configuration: configuration)
    }()
    weak var host: (any EngineExtensionHost)?
    private(set) var loaded: [EngineExtension] = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var windows: [UUID: ExtensionWindow] = [:]
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
        // Unpacked extensions: Browsa's store installs and folders the user picked.
        for folder in folders {
            let id = folder.id
            guard contexts[id] == nil else { continue }
            do {
                // Chrome extensions run from a copy with Browsa's compat script in front of the background.
                let url = try ExtensionCompat.prepare(folder.url, id: id,
                                                      in: AppFolders.support.appending(path: "Extensions (WebKit)"))
                let ext = try await WKWebExtension(resourceBaseURL: url)
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                // The same address every launch, so restored tabs showing the extension's pages still work.
                context.baseURL = Self.stableBaseURL(for: id)
                context.isInspectable = true
                grantEverything(context)
                try controller.load(context)
                contexts[id] = context
                startKeepAlive(context, folder: url)
                loaded.append(describe(ext, context: context, id: id))
                problems += (ext.errors + context.errors).map { "\(id): \($0.localizedDescription)" }
            } catch {
                problems.append("\(id): \(error)")
            }
        }
        // A Safari-app extension is skipped when the same extension came from a store or folder: the
        // Safari copy expects to reach its desktop app, which Browsa can't connect it to.
        let unpackedNames = Set(loaded.map { Self.comparableName($0.name) })
        for url in bundles {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, contexts[id] == nil else { continue }
            do {
                let ext = try await WKWebExtension(appExtensionBundle: bundle)
                if unpackedNames.contains(Self.comparableName(ext.displayName ?? "")) {
                    engineLog.info("extension: skipped the Safari copy of \(ext.displayName ?? id, privacy: .public); the store version is in use")
                    continue
                }
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                // Without a fixed address WebKit picks a new one each launch, sees the change and
                // deletes the extension's local storage and IndexedDB, so its settings and sign-ins go.
                context.baseURL = Self.stableBaseURL(for: id)
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
    /// "1Password – Password Manager" and "1Password" compare equal: the name up to any dash or colon.
    static func comparableName(_ name: String) -> String {
        let head = name.split(whereSeparator: { "–—-:|".contains($0) }).first.map(String.init) ?? name
        return head.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func describe(_ ext: WKWebExtension, context: WKWebExtensionContext, id: String) -> EngineExtension {
        let icon = ext.icon(for: CGSize(width: 32, height: 32))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let manifest = ext.manifest
        let panelPath = ((manifest["side_panel"] as? [String: Any])?["default_path"] as? String)
            ?? ((manifest["sidebar_action"] as? [String: Any])?["default_panel"] as? String)
        let panelURL = panelPath.map { context.baseURL.appending(path: $0.hasPrefix("/") ? String($0.dropFirst()) : $0) }
        return EngineExtension(id: id, name: ext.displayName ?? id, version: ext.version ?? "",
                               icon: icon, hasAction: context.action(for: nil) != nil, panelURL: panelURL,
                               optionsURL: context.optionsPageURL)
    }

    #if DEBUG
    /// Debug checks: each loaded extension's popup page, and its manifest.
    func debugPopups() -> [(id: String, name: String, popup: URL?, manifest: [String: Any], errors: [String])] {
        contexts.map { id, context in
            let m = context.webExtension.manifest
            let action = (m["action"] as? [String: Any]) ?? (m["browser_action"] as? [String: Any])
            let popup = (action?["default_popup"] as? String).map { context.baseURL.appending(path: $0.hasPrefix("/") ? String($0.dropFirst()) : $0) }
            let errors = (context.webExtension.errors + context.errors).map { "\($0.localizedDescription) \((($0 as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? "")" }
            return (id, context.webExtension.displayName ?? id, popup, m, errors)
        }
    }
    #endif

    /// Hidden pages keeping backgrounds awake, by extension id.
    private var keepAlives: [String: WKWebView] = [:]
    private var keepAliveTimers: [String: Timer] = [:]
    private var keepAliveLastPing: [String: Date] = [:]

    /// WebKit runs all of an extension's web content in one process and pauses that process once none of
    /// its pages are in use. A service worker isn't a web view, so `inactiveSchedulingPolicy` doesn't
    /// cover it: 1Password's background froze for minutes after sign-in with the popup closed. A hidden
    /// extension page that's never paused keeps the process running. It also pings the background every
    /// 20 s, since WebKit unloads a background that gets no events for 30 s (dropping its sync socket).
    private func startKeepAlive(_ context: WKWebExtensionContext, folder: URL) {
        let id = context.uniqueIdentifier
        guard FileManager.default.fileExists(atPath: folder.appending(path: ExtensionCompat.keepAlivePage).path(percentEncoded: false)),
              let configuration = context.webViewConfiguration else { return }
        configuration.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.load(URLRequest(url: context.baseURL.appending(path: ExtensionCompat.keepAlivePage)))
        keepAlives[id] = web
        keepAliveLastPing[id] = Date()
        keepAliveTimers[id]?.invalidate()
        keepAliveTimers[id] = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak web] _ in
            MainActor.assumeIsolated {
                guard let self, let web else { return }
                // A slow answer means the extension's process was paused.
                let sent = Date()
                let gap = sent.timeIntervalSince(self.keepAliveLastPing[id] ?? sent)
                self.keepAliveLastPing[id] = sent
                web.evaluateJavaScript("typeof ping === 'function' ? ping() : 0") { _, error in
                    let took = Date().timeIntervalSince(sent)
                    #if DEBUG
                    if took > 2 || gap > 30 || error != nil {
                        print("[ext] keep-alive \(id): answered after \(String(format: "%.1f", took)) s, \(String(format: "%.0f", gap)) s since last\(error.map { ", error \($0.localizedDescription)" } ?? "")")
                    }
                    #endif
                }
            }
        }
        #if DEBUG
        print("[ext] keep-alive page started for \(id)")
        #endif
    }

    /// webkit-extension://<uuid>/ derived from the extension's id.
    static func stableBaseURL(for id: String) -> URL {
        var bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = NSUUID(uuidBytes: bytes) as UUID
        return URL(string: "webkit-extension://\(uuid.uuidString.lowercased())/")!
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

    func actionState(extensionID: String, for page: WebKitPage?) -> EngineActionState? {
        guard let context = contexts[extensionID], let action = context.action(for: page) else { return nil }
        let icon = action.icon(for: CGSize(width: 16, height: 16))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return EngineActionState(label: action.label, badgeText: action.badgeText, hasUnreadBadge: action.hasUnreadBadgeText,
                                 isEnabled: action.isEnabled, icon: icon)
    }

    func performAction(extensionID: String, for page: WebKitPage?, anchor: NSView?) {
        guard let context = contexts[extensionID] else { return }
        popupAnchor = anchor
        context.performAction(for: page)
    }

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

    /// Browsa has no extension popup windows: a new window's tabs open as tabs in the window in use.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let windowID = host?.extensionWindows.first?.id
        for url in configuration.tabURLs {
            _ = host?.openExtensionTab(url: url, windowID: windowID, active: true)
        }
        completionHandler(currentWindows().first, nil)
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

    // Native messaging. WebKit only routes it to the handler inside an extension's own app, and
    // refuses it for extensions in a third-party browser, so there's nothing to forward to yet.
    // Browsa plugins will message the app itself here (host "app.browsa", see PluginRequest).

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        #if DEBUG
        // The compat diagnostics (BROWSA_EXT_DIAGNOSTICS) log through native messaging to "browsa.log".
        if applicationIdentifier == "browsa.log" {
            print("[ext-log] \(Date().timeIntervalSince1970) \((message as? [String: Any])?["line"] ?? message)")
            replyHandler(nil, nil)
            return
        }
        #endif
        replyHandler(nil, Self.noNativeMessaging(applicationIdentifier))
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // Browsa's own names, answered in-process: no helper app is started.
        if port.applicationIdentifier == ExtensionWebSocket.portName {
            ExtensionWebSocket.accept(port, for: extensionContext)
            completionHandler(nil)
            return
        }
        completionHandler(Self.noNativeMessaging(port.applicationIdentifier))
    }

    private static func noNativeMessaging(_ name: String?) -> NSError {
        NSError(domain: "Browsa.Extensions", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Browsa can't reach the app \(name ?? "") from an extension yet."])
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        host?.extensionActionsDidChange()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
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
