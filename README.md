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
tools/build_seed.py        rebuilds the seed list from Chrome UX Report top lists (see below)
tools/seed_curated.json    brand names, typed aliases (yt, gh, gmail), allow and deny lists
```

## Suggestions

Local rows come first and never move once shown: favourites, open tabs, history (frecency), the
command bar, archived tabs, and a bundled list of about 7,300 popular sites. Remote rows arrive once,
below them.

- **Seed list.** `tools/build_seed.py` ranks sites by real Chrome page loads across about 50
  countries (CrUX top lists, cached at github.com/zakird/crux-top-lists), drops adult, gambling,
  piracy and spam domains, and tags regional favourites, so someone in Australia typing "ama" gets
  amazon.com.au. Rerun it monthly: `python3 tools/build_seed.py --month 202610`.
- **Aliases.** An exact alias such as `yt`, `gh` or `gmail` puts the site on top, and Return opens it.
- **Blended remote suggestions.** The chosen engine, plus DuckDuckGo when the engine is Google, plus
  Wikipedia in the device language, all asked in parallel with a 900 ms deadline. Rows that several
  services agree on rank higher. Google site links show as a site row. Answers are cached for 10 minutes.
  Picking DuckDuckGo or Brave never sends keystrokes to Google.
- **Inline completion** only comes from the top row, and never after Backspace.

## Keyboard

Hardware shortcuts (hold ⌘ to see them): ⌘T new tab, ⌘K command bar, ⌘L address, ⌘W close,
⇧⌘T reopen closed tab, ⌘[ and ⌘] back and forward, ⌘R reload, ⌘F find, ⌘D favourite,
⌘1 to ⌘9 pick a tab, ⌃⇥ and ⌃⇧⇥ next and previous tab, ⌘S sidebar, ⌥⌘J downloads, ⌘, settings.
In the new-tab sheet, ↑ and ↓ move through rows, Return opens, Tab accepts the completion, and Esc
leaves the list and then closes the sheet.

## Not built yet

- Resizing the sidebar by dragging its edge
- Reader mode (WebKit has no public API for it, so it needs a Readability.js port)
- Drag and drop of links and favourites between the sidebar and other apps
- A downloads button in the chrome (downloads live in the command bar, ⌥⌘J and the Files app for now)
- CloudKit sync and a separate login profile for each space
- Storing history in SQLite with full-text search (GRDB + FTS5) instead of JSON, once history gets big
