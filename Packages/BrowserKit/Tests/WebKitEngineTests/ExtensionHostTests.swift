#if os(macOS)
import Foundation
import Testing
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

    /// 1Password's helper refuses a browser whose host isn't in the browser's process group.
    @Test func hostStaysInBrowsersProcessGroup() throws {
        guard #available(macOS 15.4, *) else { return }
        let host = SpawnedHost(program: URL(filePath: "/bin/sleep"), arguments: ["2"], input: Pipe(), output: Pipe())
        try host.run()
        defer { host.terminate() }
        #expect(host.processIdentifier > 0)
        #expect(getpgid(host.processIdentifier) == getpgrp())
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
