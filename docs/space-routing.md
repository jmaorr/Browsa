# Space Routing

Sites that always open in a given Space, like Arc's Air Traffic Control and Zen's Space Routing.

- Off by default. Settings › Routing › "Open sites in their Space" turns it on, and so does adding a rule
  from ⌘K ("Always Open github.com in Work", or "…github.com/acme in <this Space>" for one org).
- **Routing sets**: a set is a list of sites plus the Space they open in. The first time routing goes on,
  Browsa adds its Work tools and Watching and social sets for Spaces named like Work and Personal.
  "Add Set…" adds another of Browsa's sets, an empty one, or imports one from a file (JSON:
  `{"browsaRoutingSet": 1, "name": "…", "sites": ["…"]}`; Export writes the same). Click a set's row to
  open it; addresses edit in place; each site's ··· menu moves it to another set or a new one, or
  removes it. A set made from Browsa's can be restored to Browsa's version.
- **Custom rules**: one address, one Space, each with its own Space picker. They beat sets, and a more
  specific address (with a path, longer host) beats a shorter one.
- New tabs (⌘T, ⌘-click, favourites) and links from other apps follow the rules. Links you follow inside a
  tab never move, private tabs never move, and sign-in and checkout pages (accounts.google.com, PayPal,
  Stripe Checkout…) stay next to the tab that opened them.
- The first time a site moves, a toast says so with "Keep in <Space>", which takes that site out of its
  set (or removes the rule) and moves the tab back. ⌘K › "Stop Routing …" does the same later.

State lives in UserDefaults (`spaceRoutingEnabled`, `spaceRoutingSetList`, `spaceRoutes`,
`spaceRoutingSeeded`, `spaceRoutingAnnounced`). Code: `Mac/Sources/State/SpaceRouting.swift`, hooks in
`Browser.newTab` and `Browser.openExternal`.

Not yet: route by the app a link came from (Slack → Work), sets pushed by an organisation, sync.
