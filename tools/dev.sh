#!/bin/zsh
# One Browsa Dev build for every feature in progress (docs/dev-workflow.md).
#
# Each feature has its own worktree and branch. None of them installs an app. Instead they all feed one
# throwaway integration tree (origin/main plus every branch in the Dev set), which builds the one
# "Browsa Dev" (com.orriginal.browsa.dev) in ~/Applications. Run from a feature's worktree:
#
#   tools/dev.sh check                 # compile this worktree (Debug); installs and registers nothing
#   tools/dev.sh sync [<branch>...]    # add this branch (or those) to the Dev set, rebuild and install Browsa Dev
#   tools/dev.sh sync --rebuild        # rebuild from the set as it is (after new commits, or a merge to main)
#   tools/dev.sh drop <branch>...      # take branches out of the Dev set and rebuild
#   tools/dev.sh list                  # what the installed Browsa Dev was built from, and the set
#   tools/dev.sh done [<branch>]       # after its PR merged: out of the set, worktree and local branch removed
#   tools/dev.sh sweep                 # report strays: extra apps, registrations, finished worktrees (changes nothing)
#
# Options for sync and drop: --no-launch (never open Browsa Dev), --launch (open it even if it wasn't running).
# By default Browsa Dev is reopened only if it was running, since it restores its tabs (a call tab included).
# Only committed work is built. The integration tree and its build folder live in $BROWSA_DEV_HOME
# (default: a "dev" folder beside the main checkout) and are never merged anywhere.
set -uo pipefail

here="${0:A:h}"
main_checkout="$(git -C "$here" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
home="${BROWSA_DEV_HOME:-${main_checkout:h}/dev}"
tree="$home/tree"                      # the integration worktree
set_file="$home/branches"              # the Dev set, one branch a line
manifest="$home/installed.txt"         # what the installed app was built from
app="${BROWSA_DEV_INSTALL_PATH:-$HOME/Applications/Browsa Dev.app}"
bundle_id="com.orriginal.browsa.dev"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
g() { git -C "$main_checkout" "$@"; }
die() { echo "dev.sh: $*" >&2; exit 1; }

current_branch() {
  local b; b="$(git symbolic-ref -q --short HEAD 2>/dev/null)" || die "this worktree is on a detached HEAD; name the branch"
  [[ "$b" != main ]] || die "you're on main; run this from a feature's worktree or name the branch"
  [[ "${PWD:A}" != "${tree:A}"* ]] || die "this is the integration tree; run from a feature's worktree"
  echo "$b"
}
read_set() { [[ -f "$set_file" ]] && grep -v '^[[:space:]]*$' "$set_file" || true; }
write_set() { mkdir -p "$home"; print -l -- "$@" | grep -v '^$' | awk '!seen[$0]++' > "$set_file"; }
set_without() { local keep=() b; for b in $(read_set); do (( ${@[(Ie)$b]} )) || keep+=("$b"); done; write_set $keep; }

# One builder at a time: a second sync waits for the first.
lock() {
  mkdir -p "$home"
  local waited=0
  until mkdir "$home/lock" 2>/dev/null; do
    local pid; pid="$(cat "$home/lock/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then rm -f "$home/lock/pid"; rmdir "$home/lock" 2>/dev/null; continue; fi
    (( waited == 0 )) && echo "==> Another Dev build is running (pid ${pid:-?}); waiting"
    sleep 5; waited=$(( waited + 5 ))
    (( waited < 2400 )) || die "gave up waiting for the other Dev build after 40 minutes"
  done
  echo $$ > "$home/lock/pid"
  trap 'rm -f "$home/lock/pid"; rmdir "$home/lock" 2>/dev/null' EXIT
}

# Puts the integration tree at origin/main plus every branch in the set that merges cleanly.
# Sets: merged (branches in the build), skipped (lines to print), base (short commit of main).
integrate() {
  g fetch --quiet origin main || echo "   (couldn't fetch origin/main; using the copy here)"
  [[ -d "$tree" ]] || g worktree add --quiet --detach "$tree" origin/main || die "couldn't create $tree"
  git -C "$tree" merge --abort 2>/dev/null
  git -C "$tree" checkout --quiet --detach origin/main && git -C "$tree" reset --quiet --hard origin/main || die "couldn't reset $tree"
  base="$(g rev-parse --short origin/main)"
  merged=(); skipped=()
  local b ref files before
  for b in $(read_set); do
    if g rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then ref="$b"
    elif g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null; then ref="origin/$b"
    else skipped+=("$b: no such branch any more (removed from the set)"); continue; fi
    if g merge-base --is-ancestor "$ref" origin/main; then skipped+=("$b: already in main (removed from the set)"); continue; fi
    before="$(git -C "$tree" rev-parse HEAD)"
    if git -C "$tree" merge --quiet --no-ff --no-edit "$ref" >/dev/null 2>&1; then
      # A branch whose PR was squash-merged adds nothing: same files with it as without.
      if [[ "$(git -C "$tree" rev-parse 'HEAD^{tree}')" == "$(git -C "$tree" rev-parse "$before^{tree}")" ]]; then
        git -C "$tree" reset --quiet --hard "$before"
        skipped+=("$b: adds nothing main doesn't have (removed from the set)")
      else
        merged+=("$b")
      fi
    else
      files="$(git -C "$tree" diff --name-only --diff-filter=U | head -5 | tr '\n' ' ')"
      git -C "$tree" merge --abort 2>/dev/null
      skipped+=("$b: conflicts with main or a branch before it in the set, left out of this build (${files% })")
      keep_conflicted+=("$b")
    fi
  done
  write_set $merged ${keep_conflicted:-}
}

build() {  # build <source dir> <derived data dir> <note>; prints the built app's path on fd 3
  local src="$1" dd="$2" note="$3"
  mkdir -p "${dd:h}"
  ( cd "$src" && xcodegen generate --quiet ) || return 1
  xcodebuild -project "$src/Browsa.xcodeproj" -scheme BrowsaMac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$dd" -allowProvisioningUpdates -quiet build \
    "BROWSA_BUILD_NOTE=$note" > "$dd.log" 2>&1 || { grep -E "error:|\*\* BUILD FAILED" "$dd.log" | head -20 >&2; echo "   full log: $dd.log" >&2; return 1; }
  built="$dd/Build/Products/Debug/Browsa.app"
  [[ -d "$built" && "$(defaults read "$built/Contents/Info.plist" CFBundleIdentifier)" == "$bundle_id" ]] \
    || { echo "the build didn't give an app with the ID $bundle_id" >&2; return 1; }
  forget_built "$dd"
  return 0
}

# Xcode registers what it builds (the app and the helper apps inside it). Only the installed copy should be
# known to macOS, so every app under a build folder is unregistered.
forget_built() {
  local a
  for a in "$1"/Build/Products/*/*.app(N) "$1"/Build/Products/*/*.app/Contents/**/*.app(N); do "$lsregister" -u "$a" >/dev/null 2>&1; done
}

running() { [[ "$(osascript -e "application id \"$bundle_id\" is running" 2>/dev/null)" == true ]]; }

install() {  # install <launch: auto|yes|no>
  local launch="$1" was_running=0
  if running; then
    was_running=1
    echo "==> Quitting the running Browsa Dev"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in {1..60}; do running || break; sleep 0.25; done
    running && die "Browsa Dev didn't quit; quit it and run this again"
  fi
  echo "==> Installing $app"
  mkdir -p "$app"
  rsync -a --delete "$built/" "$app/" || die "couldn't copy the build to $app"
  forget_built "$home/build"
  "$lsregister" -f "$app" >/dev/null 2>&1
  { echo "built $(date '+%Y-%m-%d %H:%M') from main $base"; (( ${#merged} )) && print -l -- "+ "${^merged}; } > "$manifest"
  if [[ "$launch" == yes || ( "$launch" == auto && $was_running == 1 ) ]]; then open "$app"; echo "==> Browsa Dev reopened"
  else echo "==> Browsa Dev installed (not opened)"; fi
}

rebuild() {  # rebuild <launch> <branches added by this call...>
  local launch="$1"; shift
  local added=("$@") keep_conflicted=()
  lock
  echo "==> Integrating: main$( (( $(read_set | wc -l) )) && echo " + $(read_set | tr '\n' ' ')")"
  integrate
  local note="main $base$( (( ${#merged} )) && echo " + ${(j:, :)merged}")"
  echo "==> Building Browsa Dev ($note)"
  if ! build "$tree" "$home/build" "$note"; then
    if (( ${#added} )); then
      set_without $added
      die "the build failed with ${(j:, :)added} added, so it's out of the set again. Browsa Dev is unchanged."
    fi
    die "the build failed. Browsa Dev is unchanged. tools/dev.sh drop <branch> takes a branch out."
  fi
  install "$launch"
  (( ${#skipped} )) && { echo; echo "Left out:"; print -l -- "  "${^skipped}; }
  echo; cat "$manifest"
}

cmd="${1:-}"; (( $# )) && shift
launch=auto; rebuild_only=0; force=0; args=()
for a in "$@"; do
  case "$a" in --no-launch) launch=no ;; --launch) launch=yes ;; --rebuild) rebuild_only=1 ;; --force) force=1 ;; -*) die "unknown option $a" ;; *) args+=("$a") ;; esac
done

case "$cmd" in
  check)
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a checkout"
    echo "==> Compiling ${top:t} (Debug)"
    build "$top" "$top/.build/dev-check" "check ${top:t}" || die "the build failed"
    echo "==> Builds. Nothing installed; tools/dev.sh sync puts it in Browsa Dev."
    ;;
  sync)
    added=()
    if (( ! rebuild_only )); then
      if (( ! ${#args} )); then b="$(current_branch)" || exit 1; args=("$b"); fi
      for b in $args; do
        g rev-parse --verify --quiet "refs/heads/$b" >/dev/null || g rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null || die "no branch named $b"
        read_set | grep -qxF -- "$b" || added+=("$b")
      done
      [[ -z "$(git status --porcelain -uno 2>/dev/null)" ]] || echo "   note: uncommitted changes here aren't built; only commits are"
      write_set $(read_set) $args
    fi
    rebuild "$launch" $added
    ;;
  drop)
    (( ${#args} )) || die "usage: tools/dev.sh drop <branch>..."
    set_without $args
    rebuild "$launch"
    ;;
  list)
    echo "Installed Browsa Dev:"; [[ -f "$manifest" ]] && sed 's/^/  /' "$manifest" || echo "  (never built by dev.sh)"
    echo "Dev set:"; s="$(read_set)"; [[ -n "$s" ]] && echo "$s" | sed 's/^/  /' || echo "  (empty: main only)"
    ;;
  "done")
    b="${args[1]:-}"; if [[ -z "$b" ]]; then b="$(current_branch)" || exit 1; fi
    wt="$(g worktree list --porcelain | awk -v b="refs/heads/$b" '/^worktree /{w=substr($0,10)} $1=="branch" && $2==b {print w}')"
    if (( ! force )); then
      [[ -z "$wt" || -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] || die "$wt has uncommitted or untracked files (--force removes it anyway)"
      tip="$(g rev-parse --verify --quiet "refs/heads/$b" || true)"
      [[ -z "$tip" || -n "$(g branch -r --contains "$tip" 2>/dev/null | head -1)" ]] || die "$b has commits that aren't on origin (--force removes it anyway)"
    fi
    set_without "$b"
    if [[ -n "$wt" && "$wt" != "$main_checkout" ]]; then
      [[ "${PWD:A}" == "${wt:A}"* ]] && cd "$main_checkout"
      for dd in "$wt"/.build/*(N/); do forget_built "$dd"; done
      g worktree remove --force "$wt" && echo "==> Removed worktree $wt"
    fi
    g rev-parse --verify --quiet "refs/heads/$b" >/dev/null && g branch --quiet -D "$b" && echo "==> Removed local branch $b"
    echo "==> $b is out of the Dev set. tools/dev.sh sync --rebuild rebuilds Browsa Dev without it."
    ;;
  sweep)
    echo "Apps in ~/Applications besides Browsa and Browsa Dev:"
    print -l ~/Applications/Browsa*(N) | grep -vE '/Browsa( Dev)?\.app$' | sed 's/^/  /' || true
    echo "Browsa apps macOS knows about besides those two:"
    "$lsregister" -dump 2>/dev/null | awk '/^path: /{sub(/^path: +/,""); sub(/ \(0x[0-9a-f]+\)$/,""); print}' | grep -i browsa | grep '\.app$' | sort -u \
      | grep -vxF -e "$HOME/Applications/Browsa.app" -e "$HOME/Applications/Browsa Dev.app" | sed 's/^/  /' || true
    echo "Worktrees:"
    g worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | while read -r wt; do
      [[ "$wt" == "$main_checkout" || "$wt" == "$tree" ]] && continue
      h="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; br="$(git -C "$wt" symbolic-ref -q --short HEAD || echo detached)"
      state="in progress"
      if g merge-base --is-ancestor "$h" origin/main 2>/dev/null; then
        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then state="no commits beyond main, uncommitted work"
        elif [[ "$br" == detached ]]; then state="nothing beyond main"
        else state="nothing beyond main: tools/dev.sh done $br"; fi
      fi
      echo "  $wt [$br] $state, $(du -sh "$wt" 2>/dev/null | cut -f1)"
    done
    echo "App data for other bundle IDs:"
    for d in "Application Support" WebKit Caches Containers; do
      for p in ~/Library/$d/com.orriginal.browsa*(N); do
        case "${p:t}" in com.orriginal.browsa|com.orriginal.browsa.dev|com.orriginal.browsa.spike|com.orriginal.browsa.spikewelcome) ;; *) echo "  $p" ;; esac
      done
    done
    echo "Dev build folder: $(du -sh "$home" 2>/dev/null | cut -f1) in $home"
    ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
