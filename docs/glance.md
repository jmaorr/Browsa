# Glance (spike)

Option-click a link to look at it in a card over the page (Zen's Glance, Arc's Peek). Esc or a click
outside closes it; ⌘Return or the expand button opens it as a tab. Links inside stay in the card;
⌘-click and new windows become tabs. Private tabs glance privately.

Code: `NavigationRequest.wantsGlance` (set by WebKitPage for Option-click on http(s) links, before
Safari's option-click download), `TabController.page(_:decide:)`, `Mac/Sources/Views/Glance.swift`.

Not yet: hover-and-hold preview, glancing from the sidebar or ⌘K results, a setting for the modifier.
