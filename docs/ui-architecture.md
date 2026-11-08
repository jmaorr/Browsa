# Browsa Mac: where things plug in

One registry, `Workbench` (`Mac/Sources/Workbench/`), holds every tool. A `Tool` can fill any of
three places, and the window only ever asks the workbench what to show:

| Place | What it's for | How you get there |
| --- | --- | --- |
| **Right panel** | A tool you work in beside the page. Narrows the page, never covers it. One per space. | ⌥⌘S, the panel button at the top of the sidebar, the rail in the panel header, ⌘K |
| **Sidebar section** | Glanceable status under the tabs (Radar's servers). Folds away. | ⌘K "Add … to Sidebar", right-click to remove |
| **Commands** | Anything a tool can do in one step. | ⌘K, or type in ⌘T/⌘L |

⌘K is the command bar in its tools mode: a row of panel tools, then commands, with a web search as
the last row. Typing `>` in ⌘T or ⌘L switches to it.

Built-in tools register in `BuiltInTools.swift`. An extension with a `side_panel` becomes a panel
tool automatically. Browsa plugins will register from their manifest's `browsa` block through the
same `Workbench.register`.

A tool marked `stage: .preview` shows a Preview badge and runs on sample data, so its UI can be
designed in the real window before the feature exists. Radar is the first one.
