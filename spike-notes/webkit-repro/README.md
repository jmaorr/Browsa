# WebKit: a page loading an extension's files breaks that extension's background

Reproduced with the 10-line extension in `extension/` (no 1Password code), in WebKit Browsa on
macOS 26.7, sandbox on or off:

- A content script on any page `fetch()`es or `import()`s one of the extension's own files
  (`chrome.runtime.getURL(...)`, listed in web_accessible_resources).
- With a **service worker** background: about 5 s later the worker stops for good. Its timers stop,
  `runtime.sendMessage` from extension pages resolves `undefined`, and it is never restarted.
- With a **background page** (`"background": {"scripts": [...], "type": "module"}`): the page keeps
  running and answers messages, but its IndexedDB connection is closed by the browser
  ("DB CLOSED BY BROWSER", then every transaction throws InvalidStateError).
- Without the fetch/import, both run indefinitely. Giving the extension controller the tabs' website
  data store, or `inactiveSchedulingPolicy = .none` on extension web views, doesn't help.

1Password's `inline/inject-content-scripts.js` loads its real content scripts with `import()` in every
frame, so it hits this: as a service worker it goes silent; as a background page it reports
`db-terminated` and reloads.

To check next: whether Safari shows the same (load the same extension as a Safari Web Extension in an
Xcode app wrapper); whether the trigger is the page's web content process touching the extension's
origin (try an extension page in an iframe instead of fetch); then file Feedback with Apple.

## Safari comparison and timing (8 Nov)

- **Safari is fine.** The same extension, wrapped as a Safari Web Extension (`~/Developer/BrowsaShots/safari-repro`),
  fetched its file from the page on example.com and example.org, and its service worker kept running 40+ s.
- **It's a timing window in Browsa:** the background dies only if a page loads an extension file within about
  the first 5 s after the background starts. A page fetch at +8 s or +15 s is fine (worker runs the whole test).
  In Safari the worker is started on demand by the page's message, after the fetch.
- Tried in Browsa, no change: no content blocking or user scripts; tabs built from the controller's
  `webViewConfiguration`; a separate controller data store (`Configuration(identifier:)`); the tabs' data store
  for the controller; `inactiveSchedulingPolicy = .none`; `loadBackgroundContent` afterwards (reports success,
  doesn't restart it); unloading and reloading the context (no new worker).
- Workaround direction: make sure no extension-enabled page loads in the first seconds of a background's life
  (start extensions before any tab content, and hold tab loads or content-script injection briefly), and find out
  whether WebKit's later restarts of an idle background reopen the window. Report to Apple with this repro either way.
