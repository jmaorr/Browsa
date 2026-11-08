# Running 1Password's Chrome extension on WebKit (spike, 7 Nov 2026)

Test-only changes made to a local copy of 1Password's Chrome extension 8.12.44.33 (taken from the
Browsa Chromium spike's own profile) so WKWebExtension could start it:

1. `manifest.json`: `background.service_worker` -> `background/browsa-entry.js`, which imports
   `browsa-shim.js` and then the original `background.js`.
2. `popup/index.html` and `app/app.html`: `<script src="../background/browsa-shim.js">` before the
   page's own scripts.
3. `background.js`: `chrome.webNavigation.onCreatedNavigationTarget.addListener(` made optional
   (`?.addListener(`), before the shim learnt to wrap the API roots.

`browsa-shim.js` wraps `chrome`/`browser` in a proxy that hands back stand-ins for whatever WebKit
lacks, and records errors and console output into `chrome.storage.local` (`__browsaWorker`,
`__browsaErrors`) so a test can read them.

Missing in WebKit (macOS 26.7): the `idle`, `management`, `privacy`, `downloads`, `notifications`,
`offscreen`, `cookies`, `sidePanel` and `identity` namespaces; `storage.managed`;
`storage.local.setAccessLevel`; `webNavigation.onCreatedNavigationTarget`, `onHistoryStateUpdated`,
`onReferenceFragmentUpdated`, `onTabReplaced`; `tabs.onZoomChange`; `windows.onBoundsChanged`;
`runtime.onSuspend`, `onSuspendCanceled`, `onUpdateAvailable`, `onRestartRequired`;
`action.onUserSettingsChanged`; `runtime.getContexts`; dynamic `import()` in the service worker.
Properties added to WebKit's own namespace objects don't stick for later code; adding top-level
namespaces does, and so does wrapping the roots.

## Round 2 (7 Nov, later)

Fixed, and now working in WebKit Browsa:

- **Browsa started extensions before its first window existed** (`chrome.windows.getCurrent` failed).
  Library now waits for a window.
- **Extension pages in tabs were blank.** WebKit only loads `webkit-extension://` pages in web views
  made from that extension context's `webViewConfiguration`. `WebKitEngine.makePage` now uses it for
  extension URLs, `Library.openExtensionTab` makes the page with its URL, and Browsa's navigation
  policy allows the `webkit-extension` scheme.
- **The shim** wraps `chrome`/`browser` in proxies (stand-ins for missing namespaces/events, an empty
  `storage.managed`), and installs a single `runtime.onMessage` dispatcher at worker start.
- With that, 1Password's background finishes initialising ("Finished initializing 1Password"), its
  WASM core runs, it falls back from the desktop app cleanly, and its welcome page loads in a
  Browsa tab and renders 1Password's own UI.

Still blocked:

- About 2 seconds after the worker starts, its JavaScript stops: a 2-second heartbeat writes
  once and never again, later `runtime.sendMessage` from extension pages (even a ping the
  dispatcher answers itself) resolves `undefined` straight away, and nothing is logged. No crash
  report, no CPU use. The welcome page therefore gets no accounts/settings and shows
  "Something went wrong". A minimal probe extension (module service worker, three listener styles)
  works fine, so this is specific to something 1Password does early on: most likely one WebKit
  extension call that never completes and stalls that context's queue, or a synchronous wait in its
  WASM core. Needs Safari's Web Inspector on the service worker (pause, look at the stack).
- Same behaviour with the App Sandbox on and off: standalone mode doesn't need to leave the sandbox.
