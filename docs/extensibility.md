# Extending Browsa (Mac)

Three ways in, all free, all running inside WebKit:

1. **Extensions people already use.** Safari extensions from apps on the Mac (1Password,
   Bitwarden, Proton Pass…), plus Chrome Web Store and Firefox Add-ons links pasted in Settings >
   Extensions. Browsa downloads, unpacks and updates store extensions itself, once a day, and asks
   again when an update wants more permissions.
2. **Browsa plugins.** A normal web extension with a `browsa` block in its manifest, which can add a
   sidebar section, a right-panel page, commands, badges and agent tools. Each part is a
   permission people see before adding it.
3. **Agents.** A local MCP server so coding agents can use the browser, plus Margin notes they can
   read and resolve.

## Code map

| Piece | Where |
| --- | --- |
| Store links, update checks, CRX unpacking | `Packages/BrowserKit/Sources/Extensibility/ExtensionSources.swift` |
| Installed list, installer, updater | `.../Extensibility/ExtensionCatalog.swift`, `Mac/Sources/State/Library+Extensions.swift` |
| Manifest and the `browsa` block | `.../Extensibility/ExtensionManifest.swift` |
| Margin notes | `.../Extensibility/Margin.swift`, `Mac/Sources/Views/RightPanel.swift` |
| MCP toolbox (transport-free) | `.../Extensibility/AgentToolbox.swift` |
| Localhost endpoint, Agent space, asking | `Mac/Sources/Agents/` |
| Right-hand panel | `Mac/Sources/Views/RightPanel.swift` (⌥⌘S) |

## The `browsa` manifest block

```json
{
  "manifest_version": 3,
  "name": "Localhost Radar",
  "version": "1.0",
  "background": { "service_worker": "background.js" },
  "side_panel": { "default_path": "panel.html" },
  "browsa": {
    "sidebar": { "page": "sidebar.html", "title": "Dev servers" },
    "panel": { "page": "panel.html", "title": "Radar", "icon": "dot.radiowaves.left.and.right" },
    "commands": [{ "id": "open-all", "title": "Open every dev server" }],
    "agentTools": [{ "name": "radar_list", "description": "Dev servers running on this Mac" }],
    "badges": true
  }
}
```

Plugins talk to Browsa with native messaging to the host `app.browsa`
(`badge.set`, `commands.register`, `ui.toast`, `tabs.open`, `agentTool.result`, `notes.list`).
Everything else is the standard WebExtensions API, so a plugin also works as a plain extension
elsewhere.

## Agents

Turn on Settings > Agents, then for Claude Code:

```sh
claude mcp add --transport http browsa http://127.0.0.1:47913/mcp --header "Authorization: Bearer <token from Settings>"
```

Tools: `tabs_list`, `tab_open`, `page_navigate`, `page_read`, `page_screenshot`, `page_click`,
`page_type`, `page_eval` (localhost only), `notes_list`, `notes_add`, `notes_reply`,
`notes_resolve`. Agents open pages in an **Agent** space. Acting on a site asks once per site
(localhost never asks), every call shows in the Agents panel, and Stop refuses everything that
changes a page until resumed. The endpoint listens on 127.0.0.1 only, needs the bearer token, and
refuses requests that carry a web page's Origin.

## WebKit limits to design around

- **Extension frames.** When a page loads an extension's frame or file (an inline menu, an injected
  iframe), WebKit stops that extension's background a few seconds later. This only happens in
  third-party browsers, not Safari, and has been reported to Apple. Extensions that only use content
  scripts work; password-manager inline menus don't yet.
- **No API wrapping.** Wrapping `chrome.*` in a JS Proxy stops runtime messages reaching the
  background, so Chrome APIs WebKit lacks have to be filled natively, not from script.

## Password managers

Native messaging from an extension to a desktop app (how 1Password's Chrome extension talks to the
1Password app) needs that app's cooperation, so Chrome versions of password managers don't unlock
yet. The Safari versions, which ship inside the apps, do. Settings > Extensions points people there.
