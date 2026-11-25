# Browsa

A web browser for Mac (and iOS). This file is for Claude sessions working in any checkout or worktree.

## Rules that are easy to break

- **Two apps only.** Browsa (`com.orriginal.browsa`) is the released app with Josh's real sign-ins and tabs.
  Browsa Dev (`com.orriginal.browsa.dev`) is the one test build. Never make another bundle ID, product name or
  named test app, never install anything into `~/Applications` yourself, and never build or launch as
  `com.orriginal.browsa`.
- **Don't quit or launch Browsa** without Josh saying so. Browsa Dev reopens its tabs on launch (a call tab with
  the camera included), so `tools/dev.sh` only reopens it if it was already running.
- **Build output** goes only in a worktree's `.build/` or `~/Developer/Browsa/dev/build`. No new folders in
  `~/Developer`, no `derived/`.
- **Releases, website deploys and merges need Josh's go** in the conversation, each time.
- **You can't delete files** (`rm` is denied in these sessions). For a clean-up, write a script that prints what
  it would remove and deletes only with `--go`, and hand it to Josh. Don't work around the denial.

## How to do things

| task | how |
|---|---|
| Start a feature | from the main checkout: `git worktree add ../worktrees/<name> -b claude/<name> origin/main` |
| Compile | `tools/dev.sh check` |
| Try it in the app | `tools/dev.sh sync` (adds this branch to the one Browsa Dev build). `tools/dev.sh list` shows what's in it |
| Finish, after the PR merged | `tools/dev.sh done` |
| Find strays (apps, registrations, old worktrees) | `tools/dev.sh sweep` |
| Release the Mac app | `docs/mac-releases.md`: `tools/release-mac.sh`, `tools/mac-check-release.sh`, `tools/publish-mac.sh` |
| Deploy browsa.app | `website/README.md` (Cloudflare Worker `browsa-website`, from `website/` on `main`) |
| Rebuild Browsa's WebKit | `Spike/CallAudio/webkit/README.md` and `BUNDLING.md`: `prepare-webkit-tree.sh`, `build-release-webkit.sh`, then `tools/mac-bundle-webkit.sh` via the release script. About an hour and 30 GB per macOS major |
| Change Browsa's WebKit | commit in `~/Developer/Browsa/webkit/source`, then save it as a patch in `Spike/CallAudio/webkit/fixes/` and update `WEBKIT_COMMIT` and `WEBKIT_TREE`: WebKit's repository can't take the commit |

The full workflow and folder layout: `docs/dev-workflow.md`.

## Conventions

- Pull requests are squash-merged with `[skip ci]` at the end of the subject. CI runs only when started by hand.
- The repository is `jmaorr/Browsa` (its old name, `DuoBrowser`, still redirects). The main checkout is `~/Developer/Browsa/repo`.
- Scripts are zsh. Two traps: `$h:refs` applies the `:r` modifier (write `${h}:refs`), and an unquoted variable
  isn't split into words.
- Docs and comments are written in plain English for a reader who wasn't there.
