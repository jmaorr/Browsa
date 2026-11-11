# Chrome extensions on WebKit

Browsa runs extensions from the Chrome Web Store (and unpacked folders) through WebKit's
`WKWebExtensionController`. WebKit implements most of the extension platform, but extensions built
for Chrome hit a few gaps and two WebKit bugs that only show up in a third-party browser. Browsa
works around them without changing the extension's own files. With these in place, 1Password's
Chrome extension signs in, syncs, fills and does passkeys (tested 2026-11-09).

Where things are:

| What | File |
|---|---|
| Copying an extension and putting the compat script in front of its background | `Packages/BrowserKit/Sources/WebKitEngine/ExtensionCompat.swift` |
| The compat script itself | `Packages/BrowserKit/Sources/WebKitEngine/Resources/extension-compat.js` |
| Real WebSockets for service workers | `Packages/BrowserKit/Sources/WebKitEngine/ExtensionWebSockets.swift` |
| Keep-alive page, no-suspend setting, reserved native-messaging names | `Packages/BrowserKit/Sources/WebKitEngine/WebKitExtensions.swift` |

## The fixes, and why

1. **Missing Chrome APIs.** WebKit doesn't have `notifications`, `idle`, `management`, `privacy`,
   `downloads`, `offscreen`, `sidePanel`, `identity`, `storage.managed` and some events
   (`webNavigation.onCreatedNavigationTarget`, `webRequest.onAuthRequired`, …). Extensions that touch
   them at startup throw and their background never runs. The compat script adds them as plain
   objects: events that never fire, calls that answer the way a browser with nothing to report would,
   or reject with "isn't supported". **Never wrap `chrome`/`browser` in a Proxy:** WebKit then stops
   delivering `runtime.onMessage`. WebKit can also drop a namespace's JS wrapper (and anything added to
   it), so the script keeps references to what it patched.

2. **WebSockets freeze service workers (WebKit bug).** WebKit runs an extension's service worker on
   its web process's main thread, and `new WebSocket(...)` there waits on that same thread. The
   worker stops for good: no error, 0 % CPU. 1Password opens its sync socket right after sign-in, so
   sign-in spun forever. The compat script replaces `WebSocket` in workers with a stand-in that talks
   over the native-messaging port `browsa.websocket`; Browsa opens the real socket with
   `URLSessionWebSocketTask` (text and binary frames, close codes, `bufferedAmount`). Sockets carry the
   extension's origin, no cookies, at most 16 per extension and 1 MB per message.

3. **`navigator.locks` in workers.** WebKit's lock manager goes over IPC to a registry that can reject
   a service worker's requests and leave them pending. Locks only coordinate the extension's own code,
   so the compat script provides them inside the worker (exclusive/shared, FIFO per name,
   `ifAvailable`, `steal`, `signal`, `query`).

4. **Paused extension processes.** WebKit runs all of an extension's web content in one process and
   pauses it once none of its pages are in use. `inactiveSchedulingPolicy = .none` on the
   controller's web view configuration covers extension pages but not the service worker: 1Password's
   background froze for minutes after sign-in once the popup closed. Browsa keeps one hidden extension
   page (`_browsa_keepalive.html`) per extension, which is never paused and pings the background every
   20 s so it isn't unloaded as idle (which would drop its sync socket).

5. **Extension pages leaving for the web, and new windows.** An extension page that navigates to a
   website (1Password's Sign In) opens it in a normal tab, so the site gets Browsa's usual web view.
   `windows.create` opens its tabs in the current window, since Browsa has no extension popup windows.

Also: unpacked extensions get a stable `webkit-extension://` address derived from their id, so restored
tabs showing their pages still work. A Safari-app extension (1Password for Safari) is skipped when the
store version of the same extension is installed: the Safari copy expects to reach its desktop app,
which Browsa can't connect it to.

6. **Chrome constants and helpers on existing namespaces.** `offscreen.Reason`,
   `scripting.ExecutionWorld`, `runtime.getContexts`, `tabs.TAB_ID_NONE` and `windows.WINDOW_ID_*`, which
   extensions read at startup.

7. **Chrome user agent inside extensions.** These are Chrome builds, and some decide what they run in
   from `navigator.userAgent` (Bitwarden's device type is null without " Chrome/", and its background
   throws). Inside the extension only (background and its own pages), the user agent says Chrome;
   websites still see Browsa's. The compat script is also loaded into the extension's own HTML pages
   (popup, options), which use the same missing APIs.

## Compatibility (2026-11-09)

Installed from the Chrome Web Store through Browsa's own add flow and checked with the debug harness
(`BROWSA_EXT_COMPAT_CHECK`, see `Mac/Sources/Support/ExtensionCompatCheck.swift`). Nobody was signed in.

| Extension | Version | Background | Popup | Core feature | Status |
|---|---|---|---|---|---|
| 1Password | 8.12.44.33 | ✅ | ✅ | Sign-in, sync, fill, passkeys (tested signed in) | ✅ Works |
| LastPass | 4.157.0 | ✅ | ✅ log-in screen | Its field icons appear on login pages | ✅ Ready for sign-in |
| Dashlane | 6.2645.0 | ✅ | ✅ log-in screen | Marks login forms (`data-dashlane-rid`) | ✅ Ready for sign-in |
| Grammarly | 14.1345.0 | ✅ | ✅ sign-up screen | Attaches to text areas (`grammarly-extension`) | ❌ Not supported (see 2026-11-11) |
| uBlock Origin Lite | 2026.1103 | ✅ | ✅ | Blocks ad and tracker scripts (googlesyndication, google-analytics) | ✅ Works |
| Dark Reader | 4.9.135 | ✅ | ✅ | Pages go dark | ✅ Works |
| Paper Snapshot | 0.4.13 | ✅ | button, no popup | The button starts its element picker ("click to start") | ✅ Works; pasting into Paper not tried |
| Google Translate | 2.0.18 | ✅ | ✅ | Says page translation is "built into Chrome". The selected-text bubble didn't appear for a scripted selection (it may need a real mouse) | ⚠️ Partial (see 2026-11-11 below) |
| Bitwarden | 2026.10.2 | ✅ after the user-agent fix | ❌ stays on a spinner, no errors logged | Its in-page autofill script connects on every page | ❌ Popup doesn't finish loading |
| Proton Pass | 1.43.0 | ✅ | ❌ "having difficulties activating" | Not reached | ❌ Popup can't reach its background |

### Second pass (2026-11-11)

Browsa Dev from main (ad4002e), same harness, now with real AppKit key and mouse events for
extensions that ignore scripted ones (`isTrusted`).

| Extension | Version | Result | Status |
|---|---|---|---|
| uBlock Origin Lite | 2026.1103.1743 | Popup works; googlesyndication and google-analytics blocked | ✅ Verified |
| Dark Reader | 4.9.135 | Popup works; example.com goes dark | ✅ Verified |
| JSON Formatter | 0.10.2 | api.github.com shows formatted JSON with its Raw/Parsed toggle | ✅ Verified |
| Vimium | 2.4.2 | A real `f` key shows link hints; its popup works. A scripted key does nothing, as in Chrome. WebKit logs "content_scripts entry has no specified matches" for its second entry (`file:///` CSS only), which doesn't matter | ✅ Verified |
| Paper Snapshot | 0.4.13 | Snapshot and paste into Paper work (tested by hand), after adding offscreen documents and the clipboard fallback below | ✅ Verified |
| Grammarly | 14.1346.0 | Its sign-in server rejects the extension's `webkit-extension://` origin ("TOKEN_REFRESH_FAILED Invalid origin"), and the popup stays on "Grammarly is starting" (init times out). Needs Grammarly to accept Browsa; we don't fake Chrome's extension origin | ❌ Not supported |
| Bitwarden | 2026.10.2 | The popup now loads its welcome screen (Create account, Log in) instead of spinning. Its desktop-app connection fails every 10 s, as expected. Sign-in and fill not tried yet (needs an account) | ✅ Ready for sign-in |
| Proton Pass | 1.43.0 | Still "having difficulties activating". Its background logs "started" and then nothing, not even the 10 s heartbeat, so its worker seems stuck from the start; it restarts when the popup opens. Needs Web Inspector on the background | ❌ Not yet |
| Google Translate | 2.0.18 | Highlight and translate works by hand (the harness's synthetic double-click doesn't show the icon). Its bubble is a little hard to scroll; that's Google's own UI | ✅ Verified |

New in this pass:

- **Offscreen documents** (`ExtensionOffscreen.swift`). `chrome.offscreen.createDocument` makes a hidden
  extension page, one per extension, and answers once it has loaded; `hasDocument` and
  `runtime.getContexts` report it. Paper Snapshot and Google Translate use one.
- **Copying without a click.** WebKit refuses `document.execCommand('copy')` in an extension page that
  wasn't clicked. When it does, the compat script runs the page's own `copy` handler on a stand-in
  `DataTransfer` and Browsa writes the result to the pasteboard (`browsa.clipboard`), only for
  extensions with the `clipboardWrite` permission.
- **`storage.managed`** stand-in also answers Chrome's callback form. Grammarly's "Manage storage
  timeout" log lines still appear: its 3 s timer logs even when the answer came first.

Open leads for the two that don't work yet:

- **Bitwarden.** No error in the popup or background. It opens a `session` port to the background and
  then waits. Next: attach Safari's Web Inspector to the popup and background (they're inspectable in
  Debug builds) and see what it's waiting on.
- **Proton Pass.** The popup's extension API is there when the page loads (Browsa's diagnostics log
  through it), but Proton's own code replaces `chrome` afterwards and its activation message never
  reaches the background. Proton logs nothing. Next: the same, with Web Inspector.

The first launch after installing can be slow (Dashlane's and Dark Reader's popups were still loading
after 8 s on the first run, fine on the next).

## Not supported

- **Desktop-app connections** (1Password's or Bitwarden's app unlock, native messaging in general).
  Those helpers only trust a signed list of known browsers. Extensions fall back to working on their
  own (1Password: sign in inside the extension).
- APIs listed above as stand-ins don't do anything yet (notifications, downloads, side panels,
  `identity.launchWebAuthFlow`). Each can become a real Browsa feature when an extension needs it.

## Debugging

In Debug builds, `BROWSA_EXT_DIAGNOSTICS=1` adds a second script to every background that logs to
Browsa's stdout (`[ext-log]`): start, a 10 s heartbeat (and `PAUSED for Ns` if the process was
paused), errors, WebSocket opens and closes, and the *names* of incoming messages and their senders,
never their contents. Launch with `NSUnbufferedIO=YES` and redirect stdout to a file.

The diagnosis of fixes 2 and 4 follows the write-up of Lily, another WebKit browser
(github.com/pwngoblin/Lily, docs/EXTENSIONS.md). Browsa's code is its own.
