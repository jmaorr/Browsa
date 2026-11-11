# Space Routing (spike)

Sites that always open in a given Space, like Arc's Air Traffic Control and Zen's Space Routing.

- ⌘K on any site › "Always Open github.com in Work" (or "…github.com/acme in <this Space>" for one org).
- ⌘K › "Open Routing" lists rules by Space, with a field to add one ("figma.com", "github.com/acme").
- New tabs (⌘T, ⌘-click, favourites) and links from other apps follow the rules. Links you follow inside a
  tab never move. Private tabs are never routed. A path rule beats a host rule.

Rules live in UserDefaults (`spaceRoutes`). Code: `Mac/Sources/State/SpaceRouting.swift`, hooks in
`Browser.newTab` and `Browser.openExternal`.

Not yet: route by the app a link came from (Slack → Work), route on redirect, sync rules.
