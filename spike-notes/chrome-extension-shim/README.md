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

## Round 3 (8 Nov): the stall is WebKit stopping 1Password's worker at ~5 s

- New diagnostic channel: the shim logs through `runtime.sendNativeMessage('browsa.log', …)`, which
  Browsa's controller delegate prints as `[ext-log]` (Debug only). A local HTTP sink didn't work
  (mixed content from the extension's secure origin).
- Every chrome.* call 1Password's worker makes is logged with its result. All of them complete; none
  is pending. A 250 ms tick runs cleanly, then stops between 5.0 and 5.3 s after the worker starts,
  every run. No 1Password timer is running and nothing waits (`Atomics.wait` instrumented). The
  WebContent process stays alive (~286 MB, 0 % CPU). Messages from extension pages afterwards get
  `undefined`; the worker is not restarted.
- Ruled out: memory (a probe holding 250 MB keeps running), the large `storage.session` writes
  (skipped: no change), the failed `connectNative` calls (faked: no change), log throttling (1 s ticks:
  same). The probe extension (module service worker, same timers and messaging) runs for minutes.
- Next: bisect which part of 1Password's startup makes WebKit drop the worker (e.g. block its
  `navigator.locks`, IndexedDB, WebSocket/EventSource or context menu setup in turn), or catch the
  worker's last moments in Safari's Web Inspector.

## Round 4 (8 Nov): 1Password's welcome screen works

Two fixes got 1Password's Chrome extension to its own welcome/sign-in screen in WebKit Browsa:

1. **Don't wrap the global `chrome`/`browser` objects in a Proxy.** With them wrapped, WebKit no longer
   delivers `runtime.onMessage` to the background (proved with the probe extension: plain = 4/4 messages,
   with the wrap = 0/4). Missing namespaces are still added as plain properties (that works); the two
   missing members 1Password actually uses are patched in its bundle instead (Orion-style):
   `webNavigation.onCreatedNavigationTarget.addListener` -> `?.addListener`, and `browser.storage.managed`
   -> a fallback object with an empty `get` and `onChanged`.
2. **Delay the content script's `import()` until the page is ~6.5 s old** (patched in
   `inline/inject-content-scripts.js`), which avoids the WebKit stall in `../webkit-repro`.

`browsa-shim.js` is the clean layer (no diagnostics); `browsa-shim-diagnostics.js` is the instrumented one
used to find all this (logs through `sendNativeMessage('browsa.log')`). Beware: some diagnostics themselves
disturbed messaging, so judge behaviour with the clean one.

## Round 5 (8 Nov): sign-in reached, handoff not yet

Fixes this round (all in Browsa or in the patched copy of the extension):
- Extension windows (`windows.create`) open as tabs; extension pages navigating to the web open that page in a normal tab
  (1Password's "Sign in" sends its welcome tab to start.1password.com).
- Extension contexts get a stable `webkit-extension://<uuid>/` address (derived from the id) so restored tabs keep working.
- Instead of delaying `import()`, `inline/injected.js` runs as an ordinary manifest content script (all frames,
  document_idle) and `inject-content-scripts.js`'s import is a no-op, so pages never load extension files at runtime
  (the WebKit kill trigger). Background survives multi-frame pages (accounts.google.com) now.

Where it stands:
- Josh reaches 1Password's web sign-in and it accepts his details, then spins: the web page never hands the account to the
  extension. `b5.js` runs on my.1password.com (the body gets `data-onepassword-extension-version`), but no port from it ever
  reaches the background.
- 1Password's background now lives exactly 30 s, then stops, and its one-minute alarm starts it again. The probe extension
  is never unloaded and a port opened at 35 s wakes it and round-trips, so this is specific to 1Password's background.
- Next: find what makes WebKit end 1Password's worker at 30 s (likely an event or promise WebKit is waiting on), and log
  b5.js's connect attempts from the page side.

## Round 6 (8 Nov): where sign-in stops

- WebKit ends any extension background after 30 s without incoming events. A hidden extension page pinged from a native
  timer (`_browsa_keepalive.html`, `WebKitExtensions.startKeepAlive`) keeps it up: one start, 2+ minutes.
- Step log inside 1Password's `sign-in-succeeded` handler: it runs, finds the account isn't in its database yet
  (`account in db: false`), goes into adding the account (`ZdA` -> `JdA` -> `G7` sign-in), and the background stops
  about 2 s later, with no error, no CPU and never resumed. IndexedDB was healthy throughout.
- Cause: the same WebKit behaviour as in `../webkit-repro`. 1Password's sign-in page shows its inline UI as an extension
  iframe, and a page loading an extension frame or file in its first seconds stops the background about 5 s later.
  Reproduced with a 1-line content script inserting an extension iframe (`../webkit-repro/extension-iframe`).
- Inline menus are extension iframes, so this can't be avoided from the extension side. WebKit route is blocked until
  Apple fixes it or tells us the host setup Safari uses (Safari is unaffected).
