# Working on Browsa for Mac: one Dev build

There are two Browsa apps on a development Mac and no others:

| app | bundle ID | what it is |
|---|---|---|
| Browsa | `com.orriginal.browsa` | the released app, updated by Sparkle. Real sign-ins, tabs and extensions. The only one macOS offers as a web browser. |
| Browsa Dev | `com.orriginal.browsa.dev` | every feature in progress, in one build. Its own data. Never a browser to macOS (`project.yml` drops the handlers). |

No test app gets its own name or bundle ID. Each one is another entry in System Settings' browser list, another
data folder in `~/Library`, and another gigabyte of build output.

## A feature

1. A worktree and a branch, from the main checkout:
   `git worktree add ../worktrees/<name> -b claude/<name> origin/main`
2. Work and commit there. `tools/dev.sh check` compiles it (Debug). It installs nothing.
3. To try it: `tools/dev.sh sync`. That adds the branch to the **Dev set**, rebuilds Browsa Dev from
   `origin/main` plus every branch in the set, and installs it. After more commits, `tools/dev.sh sync` again.
4. Open a pull request as usual. The Dev set has nothing to do with what merges.
5. Once it's merged: `tools/dev.sh done`. The branch leaves the set, and its worktree, build folder and local
   branch go.

Several features can be in progress at once, each in its own worktree (and its own Claude thread). They all
show up in the same Browsa Dev. Its About panel says what it was built from, for example
`main 75e92de + claude/glance, claude/bangs`; so does `tools/dev.sh list`.

## What sync does when things go wrong

- **Two at once:** the second waits for the first. One build folder, one builder.
- **A branch conflicts** with main or with a branch already in the set: it's left out of that build and stays in
  the set, and the output names the files. Rebase it, then sync again.
- **The build fails** with a branch just added: that branch is taken out of the set again and Browsa Dev is left
  as it was. If nothing was added, the set stays as it is; `tools/dev.sh drop <branch>` removes one.
- **A branch is already in main** (merged, or squash-merged): it's dropped from the set.
- **Browsa Dev is open:** it quits, and reopens after the install. If it wasn't open it isn't opened, because it
  restores its tabs. `--launch` and `--no-launch` override that.

Only commits are built, never uncommitted changes.

## Where things are

Everything for Browsa is under one folder, `~/Developer/Browsa`:

| folder | what |
|---|---|
| `DuoBrowser/` | the main checkout, always on `main`. It owns the worktrees; nobody edits in it. |
| `worktrees/` | one per feature in progress |
| `dev/` | the integration tree and the one build folder behind Browsa Dev |
| `webkit/source/`, `webkit/release/` | the WebKit checkout, and its worktree with the engines the release ships |
| `releases/`, `assets/`, `backups/`, `archive/`, `research/`, `outreach/` | what shipped, marketing material, app-data backups, old material, notes |

Nothing Browsa lives beside it in `~/Developer`, and build output never goes anywhere but a worktree's own
`.build/` and `dev/build`.

`dev/` beside the main checkout (`BROWSA_DEV_HOME`): `tree/` is the integration worktree, rebuilt from scratch
each time and never merged anywhere; `build/` is its one build folder; `branches` is the Dev set;
`installed.txt` is what the installed app was built from. All of it can be deleted; the next sync makes it again.

`tools/dev.sh sweep` lists anything that has drifted from this: extra apps in `~/Applications`, Browsa apps macOS
knows about besides the two, worktrees with nothing left to merge, data folders for other bundle IDs. It changes
nothing.

Browsa Dev runs on Apple's WebKit. Engine work (Browsa's own WebKit build) is separate: `docs/mac-releases.md`.
