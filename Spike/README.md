# SpikeBrowsa

The Browsa Mac UI over mock data, with a local control channel so Claude can click, type,
screenshot and record it precisely during design passes. It compiles the same `Mac/Sources` as
Browsa plus `Spike/Sources`, behind the `SPIKE` compilation flag, so every UI change shows up here
with no copying.

## Kept apart from the daily driver

| | Browsa | SpikeBrowsa |
|---|---|---|
| Bundle ID | `com.orriginal.browsa` | `com.orriginal.browsa.spike` |
| Data | its own sandbox container | a separate container, defaults, history and website data |
| Agent (MCP) port | 47913 | 47914 (`BrowsaAgentPort` in Info.plist) |
| Default browser | can be picked | never registers for http/https |

Both can run at once.

## Mocks

- **Radar**: four dev servers (`SpikeMocks.servers`). The three that are "up" really serve pages
  on 127.0.0.1:47940, 47941 and 47943: a Northwind shop with cart and checkout forms, the same
  shop on a worktree branch, and a Storybook-style gallery. 47942 is the "exited" one.
- **Notes**: five notes on the shop pages, open, answered and resolved, from you, Claude Code and
  Codex. Seeded on first launch and after a reset.
- **Agents**: scripted sessions that call Browsa's real MCP tools through `AgentToolbox`, so the
  Agents panel, the Agent space and the notes update exactly as they would with a real agent.
  `history` runs at every launch; `fix-notes` (open, read, click, type, screenshot, add a note)
  and `blocked` (a refused call) run on request.

## Driving it

```bash
tools/spikectl build
tools/spikectl launch          # opens in the background, without taking focus
tools/spikectl shot out.png    # the window only, even while covered; 2x on Retina
tools/spikectl click 448 226   # window points from the top-left (screenshot pixels / 2)
tools/spikectl type "Grace Hopper"
tools/spikectl key k cmd       # ⌘K
tools/spikectl key return
tools/spikectl do panel '{"tool":"radar"}'
tools/spikectl agent fix-notes 0.8
tools/spikectl record 5 out.mov
tools/spikectl state           # spaces, tabs, panel, notes, agents, as JSON
tools/spikectl reset           # back to fresh mock data
```

Run `tools/spikectl` with no arguments for the full list. Everything goes over
`http://127.0.0.1:47930` (`GET /` lists the routes), so curl works too.

Input is posted into the app's own event queue: no Accessibility permission, the real pointer
never moves, and the window can stay in the background while Josh works. Screenshots and
recordings use the terminal's Screen Recording permission (`screencapture -l` and
`tools/spike-record.swift`, a ScreenCaptureKit window recorder built on first use).

### Limits

- `tree`, `find` and `press` see AppKit views (the split view, web view, window buttons), not
  SwiftUI's controls: SwiftUI only builds its accessibility tree for a real assistive client.
  Find controls by screenshot and click by coordinates.
- Clicks that open a native menu run inside that menu's tracking loop; pick items with `key`
  (arrows and return) or `key escape` to close it.
- `do` covers state that would be fiddly to reach by clicking: `newTab`, `selectSpace`,
  `selectTab`, `panel`, `toggleSidebar`, `toast`, `appearance` (light, dark, system), `resize`,
  `front`, `pauseAgents`, `clearActivity`.
