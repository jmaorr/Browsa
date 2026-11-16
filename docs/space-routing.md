# Space Routing

Sites that always open in a given Space, like Arc's Air Traffic Control and Zen's Space Routing.

- Off by default. Settings › Spaces › "Open sites in their Space" turns it on, and so does adding a site
  from ⌘K ("Always Open github.com in Work", or "…github.com/acme in <this Space>" for one org).
- With it on, Browsa's starter sets apply, matched to your Spaces by name: Work tools (Slack, Linear,
  Jira, Figma, GitHub…) go to a Space called Work, Watching and social (YouTube, Netflix, Reddit…) to
  Personal. Shopping and travel is off until you pick a Space for it. Settings can point any set at
  another Space or turn it off.
- Each starter set's sites can be edited (Settings › Spaces › Edit Sites…): take a site out, move it to
  another set or to a rule of its own, add your own, or restore Browsa's list.
- Your own sites beat the starter sets, and a path rule beats a host rule.
- New tabs (⌘T, ⌘-click, favourites) and links from other apps follow the rules. Links you follow inside a
  tab never move, private tabs never move, and sign-in and checkout pages (accounts.google.com, PayPal,
  Stripe Checkout…) stay next to the tab that opened them.
- The first time a site moves, a toast says so with "Keep in <Space>", which takes that site out of
  routing and moves the tab back. ⌘K › "Stop Routing …" does the same later.

State lives in UserDefaults (`spaceRoutingEnabled`, `spaceRoutes`, `spaceRoutingSets`, `spaceRoutingRemoved`, `spaceRoutingAdded`,
`spaceRoutingAnnounced`). Code: `Mac/Sources/State/SpaceRouting.swift`, hooks in `Browser.newTab` and
`Browser.openExternal`.

Not yet: route by the app a link came from (Slack → Work), route on redirect, sync rules.
