# The Library

`browsa://library` is where people add things to Browsa. It lists, in order:

1. **Packs**: sets of plugins switched on together. Today, the Browsa Agent Pack (Radar, Notes, Agents).
2. **Browsa Plugins**: our own tools. Off by default for new installs; onboarding (or the Agent Pack) turns them on.
3. **Privacy**: the ad and tracker blocker, cookie banner decliner and link cleaning. On by default. They're settings under the hood (`BrowserSettings.blockContent`, `declineCookieBanners`, `cleanLinks`); the Library shows them as plugins so their value is visible.
4. **Extensions**: verified extensions to add in one click, then everything you've added.

Code: `Mac/Sources/Library/LibraryPage.swift`. On/off goes through `LibraryActions.set(_:on:in:)`; onboarding should call `LibraryActions.setAgentPack(true, in:)`.

## Verified extensions

`Mac/Resources/Library/verified-extensions.json` is the list shown under "Verified to work in Browsa". Each entry is a Chrome Web Store ID plus display details:

```json
{ "id": "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "name": "1Password", "blurb": "…",
  "category": "Passwords", "tint": "#1a8cff", "tested": "2026-11-08" }
```

### Promoting an extension

1. Install it in Browsa from its Chrome Web Store link.
2. Run through the checks in the extension test list (project file `browsa-mac/extension-test-list.md`): background, popup, what it does on pages, sign-in if it has one.
3. If it all works, add an entry to `verified-extensions.json` with today's date in `tested`, and mark it ✅ in the test list.
4. Open a PR. It ships with the next build.

Later, the same file can be served from browsa.app so the list grows without an app update. Keep the format stable for that.

### What we say about the rest

The Add Chrome Extension sheet says plainly that only verified extensions are tested, and names what usually doesn't work: desktop-app unlock, DevTools panels, and anything using `chrome.debugger`.

## Safari extensions

Browsa can load Safari extensions bundled in apps on the Mac (`WKWebExtension(appExtensionBundle:)`), behind an "experimental" checkbox at the bottom of the Library. Extensions that talk to their own app through native messaging don't work: WebKit reports "Native messaging is not supported", and 1Password's helper rejects the `webkit-extension://` origin. So password managers need their Chrome extension instead. Extensions that work on their own may be fine but are untested.

## Third-party plugins (not shown yet)

`PluginInfo` is the shape a third-party plugin's manifest will map to (a `browsa` block in an extension manifest: id, title, symbol, tint, surfaces). Nothing in the app lists or loads third-party plugins yet. When we open it up, the docs for building and submitting one can be published first, and the Library gets a section once there's something to show.
