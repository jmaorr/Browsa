# Draft: Apple Feedback report (for Josh to file in Feedback Assistant)

**Area:** WebKit > Web Extensions (WKWebExtension / WKWebExtensionController)
**Type:** Incorrect/Unexpected Behavior
**Platform:** macOS 26.7.2, Xcode 27.2 (WebKit framework as shipped)

## Title

WKWebExtension background service worker stops permanently after a content script loads one of the
extension's own resources (third-party WKWebExtensionController host; Safari unaffected)

## Description

In a macOS app that hosts web extensions through the public `WKWebExtensionController` API, an
extension's background service worker stops running a few seconds after a content script on a web page
`fetch()`es or `import()`s one of the extension's own files (`browser.runtime.getURL(...)`, listed in
`web_accessible_resources`).

After that:

- the worker's timers no longer fire and it never runs again (the WebContent process stays alive,
  0 % CPU, no crash report);
- `runtime.sendMessage` from extension pages resolves `undefined` immediately;
- `WKWebExtensionContext.loadBackgroundContent(completionHandler:)` reports success but doesn't restart
  it, and unloading/reloading the context doesn't bring up a new worker.

With a background page instead of a service worker (`"background": {"scripts": [...]}`), the page
keeps running, but its IndexedDB connection is closed by the browser at the same moment (`onclose`
fires; every later transaction throws `InvalidStateError`).

The same extension, packaged as a Safari Web Extension and run in Safari, is unaffected.

This breaks real extensions: e.g. 1Password's Chrome extension loads its content scripts with
`import()` from its own package in every frame, so its background stops ~5 s after the first page loads.

## Steps to reproduce

1. Host app: create a `WKWebExtensionController` (default configuration), set it as the
   `webExtensionController` of the web views' `WKWebViewConfiguration`, load the attached extension with
   `WKWebExtension(resourceBaseURL:)` and grant its permissions and `<all_urls>`.
2. Open any web page (e.g. https://example.com) in a web view made from that configuration.
3. The content script fetches `cs-mod.js` from the extension. The background posts a heartbeat every
   second through `runtime.sendNativeMessage` (log it from the controller delegate's
   `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)`).

Also reproduced with an `<iframe>` of a `web_accessible_resources` extension page inserted by a content
script (`extension-iframe/`): same result. That's how extensions show inline UI (1Password's autofill menu and
sign-in handoff), so they can't avoid it.

## Expected

The background keeps running (heartbeats continue) and keeps answering `runtime.sendMessage`, as in Safari.

## Actual

Heartbeats stop about 4-5 s after the page's fetch; the background never runs again for the life of the app.

## Notes

- The timing matters: a fetch made well after the background has started (8-15 s) sometimes doesn't
  trigger it in the minimal extension, but 1Password's content scripts trigger it whenever they run.
- Not affected by: the controller's website data store (default, the web views' own, or
  `Configuration(identifier:)`), `WKPreferences.inactiveSchedulingPolicy = .none`, App Sandbox on or off.
- Without the content script's fetch/import, the background runs indefinitely.

## Attachments

- `extension/` (this folder): the minimal extension (manifest.json, bg.js, cs.js, cs-mod.js, app/).
- `~/Developer/BrowsaShots/safari-repro/`: the same extension as a Safari Web Extension Xcode project (works in Safari).
- A minimal host app, if Apple asks for one: the Browsa spike's `WebKitExtensions.swift` shows the setup.
- Optional: a sysdiagnose taken right after the heartbeat stops.
