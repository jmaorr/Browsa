# DuoBrowser

A personal, native WebKit browser for iPhone Duo. It brings Arc's navigation model to iOS:

- **Unfolded (inner display):** a collapsible sidebar with spaces, pinned tabs and today tabs. The
  sidebar toggle and a one-tap **New Tab** sit in the Duo's system vertical bar.
- **Folded (outer display):** a phone layout with an address pill and an Arc-style **plus** button
  at the bottom. Swipe the pill sideways to switch tabs, or up to see all tabs.
- **New-tab sheet:** the keyboard is up right away and favourites appear above it. You get
  suggestions from the first keystroke (favourites, open tabs, history ranked by frecency, a
  bundled list of popular sites and search-engine suggestions), plus inline autocomplete like Safari's.

The full plan is in the [Duo Browser build plan](https://claude.ai/artifact/ThrnaYjvkiKMqCKoukze3s).

## Build

```sh
brew install xcodegen
xcodegen            # generates DuoBrowser.xcodeproj from project.yml
open DuoBrowser.xcodeproj
```

You need Xcode 27.2 or later and the iOS 27.2 SDK. Set your development team in `project.yml` or in Xcode.

Run the suggestion engine's tests without the app:

```sh
cd Packages/BrowserKit && swift test
```

## Layout

```
App/Sources/
  DuoBrowserApp.swift      entry point, keyboard shortcuts, scene lifecycle
  Posture/PostureAdapter   every iPhone Duo API call (hinge, vertical bar) lives here
  Shell/                   RootView, UnfoldedLayout + SidebarView, FoldedLayout + BottomBar, tab switcher
  NewTab/                  NewTabSheet, AddressField (inline autocomplete), NewTabModel
Packages/BrowserKit/
  Sources/Suggest/         pure Swift: providers, ranking, frecency, inline completion, seed list
  Sources/BrowserCore/     WKWebView sessions + pool, tabs/spaces model, history store, persistence
  Tests/SuggestTests/      Swift Testing suite for the suggest engine
tools/build_seed.py        expands the seed list to the Tranco top N domains
```

## Not built yet

- Making the bottom bar shrink to a URL pill on scroll (needs a scroll-view delegate on the web view)
- Swiping in from the sidebar edge to peek at it, and resizing the sidebar by dragging
- Command bar, the archive browser UI, and the content blocker (`WKContentRuleListStore`)
- CloudKit sync and a separate login profile for each space
- Storing history in SQLite with full-text search (GRDB + FTS5) instead of JSON, once history gets big
