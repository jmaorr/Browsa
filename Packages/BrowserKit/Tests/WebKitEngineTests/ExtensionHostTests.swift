#if os(macOS)
import Foundation
import Testing
import JavaScriptCore
@testable import WebKitEngine

@Suite struct ExtensionHostTests {
    @Test func extensionPageKeepsItsQuery() throws {
        guard #available(macOS 15.4, *) else { return }
        let base = URL(string: "chrome-extension://ldgfbffkinooeloadekpmfoklnobpien/")!
        #expect(WebKitExtensions.page("index.html?action", in: base)?.absoluteString
                == "chrome-extension://ldgfbffkinooeloadekpmfoklnobpien/index.html?action")
        #expect(WebKitExtensions.page("/panel/side.html#top", in: base)?.absoluteString
                == "chrome-extension://ldgfbffkinooeloadekpmfoklnobpien/panel/side.html#top")
    }

    @Test func recognisesChromeSignInRedirects() {
        guard #available(macOS 15.4, *) else { return }
        let id = "kbfnbcaeplbcioakkpcpgfkobkghlhen"
        #expect(ExtensionAuth.redirectOwner(URL(string: "https://\(id).chromiumapp.org/?code=x&state=y")) == id)
        #expect(ExtensionAuth.redirectOwner(URL(string: "https://evil.example/\(id).chromiumapp.org/")) == nil)
        #expect(ExtensionAuth.redirectOwner(URL(string: "http://\(id).chromiumapp.org/")) == nil)
        #expect(ExtensionAuth.redirectOwner(URL(string: "https://notanid.chromiumapp.org/")) == nil)
    }

    @MainActor @Test func externalPagesFollowChromesRules() throws {
        #expect(ExtensionExternal.allowed("https://claude.ai/*"))
        #expect(ExtensionExternal.allowed("https://*.claude.ai/*"))
        #expect(!ExtensionExternal.allowed("*://*/*"))
        #expect(!ExtensionExternal.allowed("https://*.com/*"))
        let script = try #require(ExtensionExternal.script(["fcoeoabgfenejglbffodgkkbkcdhcgfn": ["https://claude.ai/*", "*://*/*"]]))
        #expect(script.source.contains("claude.ai"))
        #expect(!script.source.contains("*://*/*"))
        #expect(ExtensionExternal.script(["x": ["*://*/*"]]) == nil)
        // The page script parses.
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, e in failure = e?.toString() }
        context.evaluateScript("var window = {}, location = { protocol: 'https:', hostname: 'claude.ai', port: '', pathname: '/', search: '' };")
        context.evaluateScript(script.source)
        #expect(failure == nil)
    }

    @Test func extensionFetchOnlyForSitesTheExtensionMayReach() {
        guard #available(macOS 15.4, *) else { return }
        let granted: (URL) -> Bool = { $0.host() == "claude.ai" }
        #expect(ExtensionFetch.allowed(URL(string: "https://claude.ai/api/account")!, hasAccess: granted))
        #expect(!ExtensionFetch.allowed(URL(string: "https://bank.example/api")!, hasAccess: granted))
        #expect(!ExtensionFetch.allowed(URL(string: "file:///etc/hosts")!, hasAccess: { _ in true }))
    }

    @Test func extensionFetchSendsTheSitesCookies() throws {
        guard #available(macOS 15.4, *) else { return }
        let url = URL(string: "https://claude.ai/api/account")!
        func cookie(_ domain: String, path: String = "/", secure: Bool = false) -> HTTPCookie {
            var p: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: "k", .value: "v"]
            if secure { p[.secure] = "TRUE" }
            return HTTPCookie(properties: p)!
        }
        #expect(ExtensionFetch.matches(cookie(".claude.ai"), url))
        #expect(ExtensionFetch.matches(cookie("claude.ai", secure: true), url))
        #expect(!ExtensionFetch.matches(cookie("evil.ai"), url))
        #expect(!ExtensionFetch.matches(cookie(".notclaude.ai"), url))
        #expect(!ExtensionFetch.matches(cookie("claude.ai", path: "/other"), url))
        #expect(!ExtensionFetch.matches(cookie("claude.ai", secure: true), URL(string: "http://claude.ai/")!))
    }

    @Test func extensionFetchRedirectsDropWhatBelongsToTheFirstSite() {
        guard #available(macOS 15.4, *) else { return }
        var post = URLRequest(url: URL(string: "https://claude.ai/login")!)
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        post.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        post.setValue("session=1", forHTTPHeaderField: "Cookie")
        let elsewhere = ExtensionFetch.redirected(post, to: URL(string: "https://other.example/")!, status: 302)
        #expect(elsewhere.httpMethod == "GET")
        #expect(elsewhere.httpBody == nil)
        #expect(elsewhere.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(elsewhere.value(forHTTPHeaderField: "Cookie") == nil)
        let same = ExtensionFetch.redirected(post, to: URL(string: "https://claude.ai/home")!, status: 307)
        #expect(same.httpMethod == "POST")
        #expect(same.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(same.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func clickIDsComeOffLinks() {
        let url = URL(string: "https://shop.example/item?id=7&gclid=abc&fbclid=x&utm_source=news")!
        #expect(PrivacySwitches.withoutClickIDs(url)?.absoluteString == "https://shop.example/item?id=7&utm_source=news")
        #expect(PrivacySwitches.withoutClickIDs(URL(string: "https://example.com/?msclkid=1")!)?.absoluteString == "https://example.com/")
        #expect(PrivacySwitches.withoutClickIDs(URL(string: "https://example.com/?q=gclid")!) == nil)
    }

    @Test func userAgentNamesTheInstalledSafari() {
        #expect(SafariUserAgent.applicationName.hasPrefix("Version/"))
        #expect(SafariUserAgent.applicationName.hasSuffix(" Safari/605.1.15"))
        #expect(!SafariUserAgent.safariVersion.isEmpty)
    }

    /// 1Password's helper refuses a browser whose host isn't in the browser's process group.
    @Test func hostStaysInBrowsersProcessGroup() throws {
        guard #available(macOS 15.4, *) else { return }
        let host = SpawnedHost(program: URL(filePath: "/bin/sleep"), arguments: ["2"], input: Pipe(), output: Pipe())
        try host.run()
        defer { host.terminate() }
        #expect(host.processIdentifier > 0)
        #expect(getpgid(host.processIdentifier) == getpgrp())
    }

    @Test func spotsAnAppRefusingBrowsa() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionNativeHosts.isRefusal(["type": "error", "error": ["kind": "BrowserVerificationFailed", "reason": "UnknownBrowser"]]))
        #expect(ExtensionNativeHosts.isRefusal("UnknownBrowser"))
        #expect(!ExtensionNativeHosts.isRefusal(["type": "hello", "browser_state": "Known"]))
        #expect(!ExtensionNativeHosts.isRefusal(NSNumber(value: 3)))
    }

    @MainActor @Test func throttleHoldsOffRapidRestarts() throws {
        guard #available(macOS 15.4, *) else { return }
        do {
            let now = Date()
            for i in 0..<ExtensionNativeHosts.burst {
                try ExtensionNativeHosts.admit("test.host", origin: "chrome-extension://x/", now: now + Double(i) * 0.1)
            }
            #expect(throws: (any Error).self) {
                try ExtensionNativeHosts.admit("test.host", origin: "chrome-extension://x/", now: now + 1)
            }
            try ExtensionNativeHosts.admit("test.host", origin: "chrome-extension://x/", now: now + ExtensionNativeHosts.window + 1)
        }
    }
}
#endif
