# Web engines

Browsa's Mac app never talks to WKWebView directly. It talks to a small, engine-neutral API in
`Packages/BrowserKit/Sources/BrowserEngine`, and an engine module implements it. WebKit
(`WebKitEngine`) is the only engine today. The point of the split is that someone could add a
Chromium engine, and with it Chrome extensions, without touching tabs, spaces, the sidebar, the
command bar or suggestions.

```
Mac app (SwiftUI)          tabs, spaces, sidebar, command bar, settings
   │  uses
   ▼
BrowserEngine              protocols + value types, no WebKit
   ▲  implemented by
   │
WebKitEngine               WKWebView, content rule lists, autoconsent      (today)
ChromiumEngine             CEF or a Chromium content embedder               (someday)
```

## The API

- **`BrowserEngine`** makes pages and owns engine-wide things: blocking rules, website data,
  the private (ephemeral) profile and the downloads folder. It describes itself with
  `EngineInfo`, including `EngineCapabilities`.
- **`EnginePage`** is one tab's page: `load`, `reload`, back/forward, `zoom`, `find`,
  `sessionState()` for restoring tabs, `evaluate(_:inWorld:)` for isolated scripts, and the
  `view` to put on screen.
- **`PageState`** is an `@Observable` the engine keeps up to date (URL, title, progress,
  back/forward availability, security).
- **`EnginePageDelegate`** is the app's side: navigation policy (link cleaning, Cmd-click into a
  new tab, external schemes), popups, JavaScript dialogs, HTTP sign-in, permissions, file
  uploads, downloads, crashes. Every method has a default.

The app gates features on capabilities, never on the engine's id. Settings > Engine lists them.

## Adding a Chromium engine

The realistic route is the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef)
(CEF), which is what most third-party Chromium browsers on the Mac embed.

1. Add a `ChromiumEngine` target that wraps CEF and conforms to `BrowserEngine`. Each
   `CefBrowser` becomes an `EnginePage`; its `NSView` is the page's `view`.
2. Map CEF's handlers onto the delegate: `CefRequestHandler.OnBeforeBrowse` →
   `page(_:decide:)`, `CefLifeSpanHandler.OnBeforePopup` → `page(_:openedPopup:url:)`,
   `CefJSDialogHandler` → `page(_:show:)`, `CefDownloadHandler` → `EngineDownload`,
   `CefDisplayHandler` → `PageState`.
3. Profiles: a `CefRequestContext` with a cache path for `.standard`, an in-memory one for
   `.ephemeral`.
4. Blocking: translate the same AdGuard lists into Chromium's declarativeNetRequest rules (or
   block in `OnBeforeResourceLoad`), keyed by the same rule group names.
5. Session restore: CEF has no equivalent of WebKit's `interactionState`, so `sessionState()`
   would hold the URL and the back/forward list as JSON and replay them.
6. Extensions: CEF's extension support is partial (Chrome Web Store installs, MV3 service
   workers and many `chrome.*` APIs are missing). Full Chrome extension support means building on
   Chromium's own `content` layer instead, a much bigger project (this is what Arc, Brave and
   Edge do). Either way it would report `.chromeExtensions`.
7. In `BrowsaMacApp`, choose the engine at launch, e.g. from a setting.

Things to know before starting:

- **Size and distribution.** CEF adds roughly 200–300 MB and several helper apps. It can't go
  through the Mac App Store's sandbox easily, so a Chromium build would ship as a separate,
  directly downloaded, notarised app (with Sparkle for updates).
- **iOS.** Apple only allows other engines on iOS in the EU, under separate entitlements, so the
  iPhone app stays on WebKit.
- **Licences.** Chromium and CEF are BSD-licensed, compatible with the app's MIT licence.

## Status

- The Mac app uses `BrowserEngine` throughout.
- The iPhone app still uses BrowserCore's `TabSession` and `WebViewPool` directly. Moving it onto
  `BrowserEngine` (with a UIKit flavour of `WebKitEngine`) is the next step, and would let the two
  apps share the browser state that's currently duplicated in `Mac/Sources/State`.
