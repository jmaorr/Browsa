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
ChromiumEngine             a self-built Chromium/CEF                        (parked)
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

## Chromium: what we tried (November 2026)

We spiked a Chromium engine on the prebuilt [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef)
(CEF 156) to get Chrome extensions such as 1Password. The findings, so nobody repeats them blind:

- **Alloy style** (CEF's embeddable view) has no extension system.
- **Chrome style** has real Chrome extensions and the Web Store, and 1Password's Chrome extension
  worked unmodified. But CEF only creates Chrome-style pages in its own top-level windows, and
  allows one per window:
  - moving a Chrome-style page's view into Browsa's window draws fine, but real mouse and
    keyboard input is lost inside Chrome;
  - using CEF's window as Browsa's window caps it at one page, ever ("Cannot add multiple
    Chrome style BrowserViews");
  - one CEF window per tab, swapped in place, takes input but crashed inside CEF on switching.
- **Media.** Prebuilt CEF plays VP9/AV1 and Widevine, but not H.264, AAC or HEVC. Those need a
  CEF build from source with proprietary codecs.
- **Cost.** About 340 MB, outside the Mac App Store, roughly 2x Chrome's memory with one window
  per tab.

So Browsa owning its own tabs and UI on Chromium means building Chromium (or CEF with patches)
from source, like Arc, Brave and Edge. That's parked until it's worth a dedicated build machine.

We also tried Chrome extensions on WebKit (`WKWebExtension`). Most of the plumbing works, but in a
third-party app WebKit stops an extension's background a few seconds after a page loads an
extension frame or file (Safari is unaffected; reported to Apple). Password managers' inline menus
are extension frames, so they don't work there yet. Content-script extensions are fine.

If someone does take up a Chromium engine, the mapping is: each `CefBrowser` is an `EnginePage`;
`CefRequestHandler.OnBeforeBrowse` → `page(_:decide:)`, `CefLifeSpanHandler.OnBeforePopup` →
`page(_:openedPopup:url:)`, `CefJSDialogHandler` → `page(_:show:)`, `CefDownloadHandler` →
`EngineDownload`, `CefDisplayHandler` → `PageState`; a `CefRequestContext` per profile; AdGuard
lists as declarativeNetRequest rules; `sessionState()` as JSON of the back/forward list.

- **iOS.** Apple only allows other engines on iOS in the EU, under separate entitlements, so the
  iPhone app stays on WebKit.
- **Licences.** Chromium and CEF are BSD-licensed, compatible with the app's MIT licence.

## Status

- The Mac app uses `BrowserEngine` throughout.
- The iPhone app still uses BrowserCore's `TabSession` and `WebViewPool` directly. Moving it onto
  `BrowserEngine` (with a UIKit flavour of `WebKitEngine`) is the next step, and would let the two
  apps share the browser state that's currently duplicated in `Mac/Sources/State`.
