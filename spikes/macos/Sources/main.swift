// Mac viability spike: a bare WKWebView browser that records what the platform allows.
// See spikes/macos/README.md for how to run it and what each probe proves.
import AppKit
import AuthenticationServices
import WebKit

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
func options(_ name: String) -> [String] {
    arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

/// A one-window, one-tab model is all WKWebExtension needs to run real extension APIs.
final class SpikeWindow: NSObject, WKWebExtensionWindow {
    weak var browser: Browser?
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { browser.map { [$0.tab] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { browser?.tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { browser?.window.frame ?? .zero }
}

final class SpikeTab: NSObject, WKWebExtensionTab {
    weak var browser: Browser?
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser?.extensionWindow }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { browser?.webView }
    func title(for context: WKWebExtensionContext) -> String? { browser?.webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { browser?.webView.url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(browser?.webView.isLoading ?? false) }
}

@MainActor
final class Browser: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    WKWebExtensionControllerDelegate, NSTextFieldDelegate
{
    let controller = WKWebExtensionController()
    let extensionWindow = SpikeWindow()
    let tab = SpikeTab()
    var contexts: [WKWebExtensionContext] = []
    var webView: WKWebView!
    var window: NSWindow!
    var address: NSTextField!
    var report: [String: Any] = [:]
    var extensionReports: [[String: Any]] = []
    var popupReport: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        extensionWindow.browser = self
        tab.browser = self
        controller.delegate = self

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = controller
        configuration.userContentController.add(self, name: "spike")
        // "safari" gives the `Version/x Safari/x` suffix a plain WKWebView lacks; "default" keeps WebKit's own.
        let userAgent = option("--ua") ?? "safari"
        if userAgent == "safari" {
            configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Browsa Mac spike"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        address = NSTextField(string: "")
        address.placeholderString = "Enter a URL"
        address.delegate = self
        let stack = NSStackView(views: [address, webView])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        report["userAgentMode"] = userAgent
        probePasskeyAuthorization()
        loadExtensions()

        controller.didOpenWindow(extensionWindow)
        controller.didFocusWindow(extensionWindow)
        controller.didOpenTab(tab)
        controller.didActivateTab(tab, previousActiveTab: nil)

        if let url = option("--url").flatMap(URL.init(string:)) { load(url) }
        // WebAuthn needs a focused document and a user gesture, so the probe clicks its own page.
        if arguments.contains("--click") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.clickPage() }
        }
        if let seconds = option("--report-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.finish() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func load(_ url: URL) {
        address.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = address.stringValue
        if let url = URL(string: text.contains("://") ? text : "https://\(text)") { load(url) }
        return true
    }

    func clickPage() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        report["windowIsKey"] = window.isKeyWindow
        // The page only reports focus a moment after the window takes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sendClick() }
    }

    func sendClick() {
        let point = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    // MARK: Passkeys

    func probePasskeyAuthorization() {
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        let state: String
        switch manager.authorizationStateForPlatformCredentials {
        case .authorized: state = "authorized"
        case .denied: state = "denied"
        case .notDetermined: state = "notDetermined"
        @unknown default: state = "unknown"
        }
        report["passkeyAuthorizationState"] = state
        if #available(macOS 26.2, *) {
            report["deviceConfiguredForPasskeys"] = ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
        }
        report["hasPasskeyEntitlement"] = entitlement("com.apple.developer.web-browser.public-key-credential")
        report["sandboxed"] = entitlement("com.apple.security.app-sandbox")
    }

    func entitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool ?? false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        report["page", default: [String: Any]()] = body
    }

    // MARK: Extensions

    func loadExtensions() {
        for path in options("--ext") {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in
                var entry: [String: Any] = ["path": url.lastPathComponent]
                do {
                    let parsed: WKWebExtension
                    if url.pathExtension == "appex", let bundle = Bundle(url: url) {
                        parsed = try await WKWebExtension(appExtensionBundle: bundle)
                    } else {
                        parsed = try await WKWebExtension(resourceBaseURL: url)
                    }
                    entry["name"] = parsed.displayName ?? "?"
                    entry["version"] = parsed.version ?? "?"
                    entry["manifestVersion"] = parsed.manifestVersion
                    entry["hasBackground"] = parsed.hasBackgroundContent
                    entry["parseErrors"] = parsed.errors.map(\.localizedDescription)
                    // Parsing only, for extensions that hold real data such as a password manager.
                    if options("--parse-only").contains(path) {
                        extensionReports.append(entry)
                        return
                    }
                    let context = WKWebExtensionContext(for: parsed)
                    context.isInspectable = true
                    for permission in parsed.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
                    for pattern in parsed.requestedPermissionMatchPatterns.union(parsed.optionalPermissionMatchPatterns) {
                        context.setPermissionStatus(.grantedExplicitly, for: pattern)
                    }
                    context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
                    try controller.load(context)
                    contexts.append(context)
                    entry["loaded"] = true
                } catch {
                    entry["loadError"] = String(describing: error)
                }
                extensionReports.append(entry)
            }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [extensionWindow] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { extensionWindow }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) { completionHandler(permissions, nil) }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) { completionHandler(urls, nil) }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let popup = action.popupWebView else {
            completionHandler(nil)
            return
        }
        popup.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let host = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = popup
        host.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            popup.evaluateJavaScript("document.body.innerText") { value, error in
                self.popupReport["text"] = value ?? String(describing: error)
            }
        }
        completionHandler(nil)
    }

    // MARK: Report

    func finish() {
        for context in contexts { context.performAction(for: tab) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let script = "JSON.stringify({title:document.title,url:location.href,ua:navigator.userAgent,text:document.body?document.body.innerText.slice(0,400):'',probe:window.__probe||null,ext:document.documentElement.dataset.extProbe||null})"
            self.webView.evaluateJavaScript(script) { value, error in
                self.report["finalPage"] = value ?? String(describing: error)
                self.report["extensions"] = self.extensionReports
                self.report["runtimeErrors"] = self.contexts.map { ["\($0.webExtension.displayName ?? "?")": $0.errors.map(\.localizedDescription)] }
                self.report["popup"] = self.popupReport
                let data = try? JSONSerialization.data(withJSONObject: self.report, options: [.prettyPrinted, .sortedKeys])
                let output = option("--report") ?? NSTemporaryDirectory() + "spike-report.json"
                FileManager.default.createFile(atPath: output, contents: data)
                NSApp.terminate(nil)
            }
        }
    }

    // Lets page-opened passkey prompts and popups stay in this one window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let browser = Browser()
    app.delegate = browser
    app.setActivationPolicy(.regular)
    app.run()
}
