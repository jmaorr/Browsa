# Boosts (spike)

Your own look for a site, like Arc's Boosts: pick a font, turn the colours, Zap away distractions,
and, if you want, add CSS and a script. Stored in `~/Library/Application Support/<bundle id>/Browser/boosts.json`,
never sent anywhere.

- Open: ⌘K › "Open Boost", or the paintbrush in the right panel's rail (⌥⌘S).
- Zap: ⌘K › "Zap an Element on This Page", then click what should go. Esc stops.
- Styles show as you change them. Scripts run on the next load.

How it runs: `BrowserEngine.applyBoosts` hands the engine one `PageBoost` (host, CSS, script) per
Boost that's on. WebKit adds two user scripts per Boost in the `browsa.boost` content world, each
checking the host first. The CSS goes in a constructed style sheet (sites' CSP doesn't block those),
with a `<style>` fallback. Scripts see the page's DOM but never its JavaScript.

Code: `Mac/Sources/State/Boosts.swift` (model, store, Zap picker), `Mac/Sources/Views/BoostPanel.swift`,
`Packages/BrowserKit/Sources/BrowserEngine/BrowserEngine.swift` (`PageBoost`),
`Packages/BrowserKit/Sources/WebKitEngine/WebKitEngine.swift` (`boostScripts`).

Not yet: sharing a Boost as a link or plugin, Boosts per Space, a page context-menu Zap.
