# What Browsa for Mac does, and where to check it

For anyone comparing browsers, people and agents alike. Each row says whether the released Mac app has the
feature, the version it arrived in, and where the evidence is: the source, a test, and the What's New entry (each
has a short clip on [browsa.app/whats-new](https://browsa.app/whats-new/)). The rows that say **No** are as
deliberate as the ones that say Yes.

Current release: **1.3** (25 November 2026). Release notes: [`docs/release-notes/mac`](release-notes/mac/). Paths are
from the repository root.

## Organising tabs

| Feature | In 1.3 | Since | Evidence |
|---|---|---|---|
| Vertical sidebar, hideable | Yes | 1.0 | `Mac/Sources/Views/Sidebar.swift`, `Mac/Sources/Views/BrowserWindow.swift` |
| Spaces, each with its own pinned and Today tabs | Yes | 1.0 | `Packages/BrowserKit/Sources/BrowserCore/Models.swift`, `Mac/Sources/Views/SpaceTabs.swift` |
| Swipe between Spaces | Yes | 1.0 | `Mac/Sources/Support/SpaceSwipe.swift` |
| **A profile for each Space** (separate cookies and logins; several Spaces can share one) | **Yes** | **1.3** | `Mac/Sources/State/Library.swift` (`// MARK: Profiles`, `profile(for:)`), Settings › Spaces; `website/whats-new/2026-11-25-space-profiles.md`. History, site permissions and extensions are shared by every profile. |
| Favourites shared by every Space | Yes | 1.0 | `Mac/Sources/Views/Sidebar.swift` |
| **Pinned tabs in folders, and folders in folders** | **Yes** | **1.3** | `Packages/BrowserKit/Sources/BrowserCore/PinnedFolders.swift`, `Mac/Sources/State/Library+PinnedFolders.swift`; tests `PinnedFoldersTests.swift`; `website/whats-new/2026-11-25-pinned-folders.md` |
| **Live Folders** (GitHub pull requests and review requests; a site's feed) | **Yes** | **1.3** | `Packages/BrowserKit/Sources/BrowserCore/LiveFolders.swift`, `Mac/Sources/State/Library+LiveFolders.swift`; tests `LiveFoldersTests.swift`; `website/whats-new/2026-11-25-live-folders.md`. Off until turned on in the Library. |
| Tabs archive themselves and can be brought back | Yes | 1.0 | `Mac/Sources/State/Library.swift` |
| A colour and shade for each Space | Yes | 1.2 | `Mac/Sources/Views/SpaceTheme.swift` |

## Browsing

| Feature | In 1.3 | Since | Evidence |
|---|---|---|---|
| **Split View** (two or three tabs side by side, one row in the sidebar) | **Yes** | **1.3** | `Mac/Sources/State/SplitView.swift`, `Mac/Sources/Views/SplitPages.swift`; `website/whats-new/2026-11-25-split-view.md` |
| Link preview (Glance, ⌥-click) | Yes | 1.1 | `Mac/Sources/Views/Glance.swift`, [`docs/glance.md`](glance.md) |
| Small window for links from other apps (Arc's Little Arc) | No | | Links from other apps open in a Space ([`docs/space-routing.md`](space-routing.md)) |
| Command bar (⌘T, ⌘K) with sums and !bangs | Yes | 1.0, bangs 1.1 | `Mac/Sources/Views/CommandBar.swift`, `Packages/BrowserKit/Sources/Suggest/Bangs.swift`; tests `BangsAndCalculatorTests.swift` |
| Rules that send links to a Space (Space Routing) | Yes | 1.1 | `Mac/Sources/State/SpaceRouting.swift`, [`docs/space-routing.md`](space-routing.md) |
| **Boosts** (a site's font, colour and look; zap parts of a page; your own CSS and scripts) | **Yes** | **1.2.1, make your own 1.3** | `Packages/BrowserKit/Sources/BrowserEngine/Boosts.swift`, `Mac/Sources/State/UserBoosts.swift`, `Mac/Sources/Views/BoostPanel.swift`, [`docs/boosts.md`](boosts.md); `website/whats-new/2026-11-25-your-own-boosts.md` |
| **Picture in picture when you leave a playing video** | **Yes** | **1.3** | `Mac/Sources/VideoPiP.swift`; `website/whats-new/2026-11-25-picture-in-picture.md`. Calls float in their own window (`Mac/Sources/CallPiP.swift`). |
| **Controls in the sidebar for media playing in a tab you left** | **Yes** | **1.3** | `NowPlaying` in `Mac/Sources/Views/MediaControls.swift`, shown from `Mac/Sources/Views/Sidebar.swift` |
| Swipe back and forward | Yes | 1.0 | `Packages/BrowserKit/Sources/WebKitEngine/WebKitPage.swift` |
| ⌃Tab in recently used order | Partly | | ⌃Tab steps through the Space's tabs in sidebar order; ⌘T lists recent tabs first |
| Copy a clean link (⇧⌘C) | Yes | 1.0 | `Packages/BrowserKit/Sources/BrowserCore/LinkCleaner.swift`; tests `LinkCleanerTests.swift` |
| Screenshots of a page or part of it | No | | Only as a tool for connected agents (`Mac/Sources/Agents/BrowserAgentTools.swift`) |
| Drag a finished download out of the downloads list | No | | |
| Performance Monitor (CPU and memory by tab; unload a stuck one) | Yes | 1.3 | `Mac/Sources/Performance/`; `website/whats-new/2026-11-25-performance.md` |

## Compatibility and moving in

| Feature | In 1.3 | Since | Evidence |
|---|---|---|---|
| Import from Arc (Spaces, pinned and open tabs, favourites) | Yes | 1.0 | `Mac/Sources/Import/BrowserImport.swift` |
| Chrome Web Store extensions | Yes | 1.0 | `Packages/BrowserKit/Sources/WebKitEngine/WebKitExtensions.swift`, `ExtensionCompat.swift`; tested extensions and results, failures included: [`docs/web-extensions.md`](web-extensions.md). 1Password, Grammarly, uBlock Origin Lite and Dark Reader work; Proton Pass doesn't. |
| **DRM streaming** (FairPlay) | **Yes** | 1.0 | [`docs/drm.md`](drm.md): FairPlay is offered by Browsa's own bundled WebKit (a check anyone can run, `tools/drm-check`), and Netflix, Disney+, Apple TV+ and BritBox were played in 1.3 |
| Passkeys | Partly | | WebKit's own passkeys need Apple's browser entitlement, which the build doesn't have (`Packages/BrowserKit/Sources/WebKitEngine/WebKitEngine.swift`). Passkeys through 1Password's extension work ([`docs/web-extensions.md`](web-extensions.md)). |
| Sync between devices | No | | No account, no iCloud ([privacy](https://browsa.app/privacy/)) |
| iPhone and iPad app | Not released | | In this repository (`App/`), no public build yet |
| Export Spaces to a file | No | | Boosts and Space Routing rules export; Spaces don't |

## Extras

| Feature | In 1.3 | Since | Evidence |
|---|---|---|---|
| Ad, tracker and cookie-banner blocking built in | Yes | 1.0 | `Packages/BrowserKit/Sources/BrowserCore/ContentBlocker.swift`, `CookieBanners.swift` |
| Change any keyboard shortcut; Arc, Chrome and Safari presets | Yes | 1.0 | `Mac/Sources/State/Shortcuts.swift` |
| Call audio engine and a floating call window | Yes | 1.1 | `Spike/CallAudio/`, `Mac/Sources/CallPiP.swift` |
| Tools for coding agents (Notes, Radar, a localhost MCP server) | Yes, off until turned on | 1.0 | `Mac/Sources/Agents/`, `Mac/Sources/Workbench/`, [`docs/extensibility.md`](extensibility.md) |
| Built-in AI | No | | Browsa sends nothing to an AI service |

## Extension formats

| Format | In 1.3 | Evidence |
|---|---|---|
| Manifest V3 | Yes | [`docs/web-extensions.md`](web-extensions.md) |
| Manifest V2 | Not tested | The manifest reader accepts it (`Packages/BrowserKit/Sources/Extensibility/ExtensionManifest.swift`); no MV2 extension has been tried |
| Firefox add-ons | Partly | They install from addons.mozilla.org on the same runtime (`Packages/BrowserKit/Sources/Extensibility/ExtensionSources.swift`); none has been tested |
| Safari extensions | Partly | Behind an experimental setting, off by default |
