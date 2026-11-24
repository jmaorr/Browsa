# Boosts

A Boost gives a site a new look. There are two kinds, shown together everywhere:

- **Ready-made Boosts** (`Packages/BrowserKit/Sources/BrowserEngine/Boosts.swift`, type `Boost`): Browsa's own,
  like LinkedIn Tidy Feed. Turned on by id; stored in UserDefaults under the 1.2.1 key `siteStyles`.
- **Your own Boosts** (`Mac/Sources/State/UserBoosts.swift`, type `SiteBoost`): one per site, made in the
  Boosts panel. A font, a tint (eight soft presets or anywhere on the colour strip), elements zapped away,
  and optional CSS and a script. Stored in `~/Library/Application Support/<bundle id>/Browser/boosts.json`,
  never sent anywhere. Private tabs can't make or change one (that would write the site to disk), but
  Boosts you made still apply there.

Where to find them: the site icon menu in the address bar (Boosts heading: ready-made toggles, My Boost,
Boost This Site… / Edit Boost…, Zap Something…), the Boosts panel in the right panel's rail, ⌘K ("Zap
Something on This Page", "Turn Boost On or Off for This Site"), and Settings › General › Boosts.

How your own run: `BoostsConfigurable.userBoosts` hands the engine one `PageBoost` (host, CSS, script) per
Boost that's on. WebKit adds two user scripts per Boost in the `browsa.boost` content world, each checking
the host first. The CSS goes in a constructed style sheet (sites' CSP doesn't block those), with a
`<style>` fallback. Scripts see the page's DOM but never its JavaScript. The panel previews style changes
on the open page straight away (`PageBoost.previewSource`) and saves after a short pause, since saving
reloads every page's user scripts.

Not yet: sharing a Boost, Boosts per Space, a page context-menu Zap.
