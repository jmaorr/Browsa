#if os(macOS)
import AppKit
import WebKit
import BrowserEngine

/// Web extensions run by WebKit's WKWebExtensionController: Safari extensions inside the user's
/// apps, and unpacked folders (store installs and ones the user picked).
///
/// Extensions get the permissions they ask for: the user saw them on the add sheet, or, for
/// Safari extensions, when they installed the app. Per-site prompts come later.
@available(macOS 15.4, *)
@MainActor
final class WebKitExtensions: NSObject, WKWebExtensionControllerDelegate {
    let controller = WKWebExtensionController()
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
                let ext = try await WKWebExtension(resourceBaseURL: folder.url)
                let context = WKWebExtensionContext(for: ext)
                context.uniqueIdentifier = id
                context.isInspectable = true
                grantEverything(context)
                try controller.load(context)
                contexts[id] = context
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
        replyHandler(nil, Self.noNativeMessaging(applicationIdentifier))
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(Self.noNativeMessaging(port.applicationIdentifier))
    }

    private static func noNativeMessaging(_ name: String?) -> NSError {
        NSError(domain: "Browsa.Extensions", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Browsa can't reach the app \(name ?? "") from an extension yet."])
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
