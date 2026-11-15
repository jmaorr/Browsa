#!/bin/zsh
# Moves the everyday Browsa (~/Applications/Browsa.app, com.orriginal.browsa) onto Browsa's own WebKit build, with a
# backup first and a way back. Nothing here runs by itself: each step is a subcommand.
#
#   tools/daily-patched-webkit.sh backup              # quits Browsa, snapshots its app and data (APFS clones)
#   tools/daily-patched-webkit.sh install [<ref>]     # backup, then install-mac.sh --patched-webkit <ref>
#   tools/daily-patched-webkit.sh status              # which WebKit the running Browsa is on
#   tools/daily-patched-webkit.sh off                 # stay on the system WebKit from the next start (keeps the install)
#   tools/daily-patched-webkit.sh rollback [<backup>] # quits Browsa, puts the backed-up app and data back
#
# Why a data backup: Browsa's WebKit is newer than the system's (627 against 624 on macOS 26.7), and may upgrade
# website data files (IndexedDB, local storage, the tracking prevention database) in place; the system WebKit might
# then not read them. The network cache is per version and needs nothing. Cookies are CFNetwork's, not WebKit's.
# Backups go to ~/Developer/Browsa/backups/daily-<time> as APFS clones (no extra disk until files change).
set -euo pipefail

repo="${0:A:h:h}"
bundle_id="com.orriginal.browsa"
app="$HOME/Applications/Browsa.app"
backups="$HOME/Developer/Browsa/backups"
webkit="$HOME/Developer/BrowsaWebKit/WebKitBuild/Browsa-daily"
# Everything that holds Browsa's state, as installed today (unsandboxed; SandboxMigration moved it out).
data=(
  "$HOME/Library/WebKit/$bundle_id"
  "$HOME/Library/HTTPStorages/$bundle_id"
  "$HOME/Library/HTTPStorages/$bundle_id.binarycookies"
  "$HOME/Library/Application Support/$bundle_id"
)
# Preferences go through cfprefsd (defaults export / import), not as a file: it caches them.

running() { [[ "$(osascript -e "application id \"$bundle_id\" is running")" == true ]]; }
quit_browsa() {
  running || return 0
  echo "==> Quitting Browsa (tabs are saved on quit)"
  osascript -e "tell application id \"$bundle_id\" to quit" || true
  for _ in {1..80}; do running || return 0; sleep 0.25; done
  echo "Browsa didn't quit; quit it and run this again" >&2; exit 1
}

backup() {
  quit_browsa
  local dest="$backups/daily-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest/data"
  echo "==> Backing up to $dest"
  [[ -d "$app" ]] && cp -cR "$app" "$dest/Browsa.app"
  for p in "${data[@]}"; do
    [[ -e "$p" ]] || continue
    local rel="${p#$HOME/}"
    mkdir -p "$dest/data/${rel:h}"
    cp -cR "$p" "$dest/data/$rel"
  done
  defaults export "$bundle_id" "$dest/preferences.plist"
  git -C "$repo" rev-parse --short HEAD > "$dest/browsa-repo-head.txt" 2>/dev/null || true
  echo "$dest" > "$backups/latest-daily"
  du -sh "$dest" | sed 's/^/   size (as clones, shared until changed): /'
  echo "$dest"
}

case "${1:-}" in
  backup) backup ;;
  install)
    ref="${2:-origin/claude/project-thread-9pc6im}"
    [[ -e "$webkit/WebKit.framework/Versions/A/WebKit" ]] || { echo "No Browsa WebKit at $webkit" >&2; exit 1; }
    backup
    "$repo/tools/install-mac.sh" --patched-webkit "$ref"
    sleep 4
    echo "==> $(tail -1 "$HOME/Library/Logs/Browsa/webkit.log" 2>/dev/null)"
    echo "Settings › Audio shows which WebKit it's on. To go back: $0 off (quick) or $0 rollback (app and data)."
    ;;
  status)
    pid=$(pgrep -nf "$app/Contents/MacOS/Browsa" || true)
    [[ -n "$pid" ]] || { echo "Browsa isn't running"; exit 0; }
    if lsof -p "$pid" -Fn 2>/dev/null | grep -q "^n$webkit/WebKit.framework/"; then echo "Browsa's WebKit ($webkit)"; else echo "system WebKit"; fi
    tail -1 "$HOME/Library/Logs/Browsa/webkit.log" 2>/dev/null || true
    ;;
  off)
    defaults write "$bundle_id" patchedWebKit -bool false
    echo "Browsa will start on the system WebKit next time (Settings › Audio to switch back on)."
    ;;
  rollback)
    src="${2:-$(cat "$backups/latest-daily" 2>/dev/null || true)}"
    [[ -n "$src" && -d "$src" ]] || { echo "No backup given or recorded in $backups/latest-daily" >&2; exit 1; }
    quit_browsa
    aside="$backups/replaced-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$aside/data"
    echo "==> Moving the current app and data aside to $aside (nothing deleted)"
    [[ -d "$app" ]] && mv "$app" "$aside/Browsa.app"
    for p in "${data[@]}"; do
      [[ -e "$p" ]] || continue
      local_rel="${p#$HOME/}"
      mkdir -p "$aside/data/${local_rel:h}"
      mv "$p" "$aside/data/$local_rel"
    done
    echo "==> Restoring from $src"
    [[ -d "$src/Browsa.app" ]] && cp -cR "$src/Browsa.app" "$app"
    for p in "${data[@]}"; do
      local_rel="${p#$HOME/}"
      [[ -e "$src/data/$local_rel" ]] || continue
      mkdir -p "${p:h}"
      cp -cR "$src/data/$local_rel" "$p"
    done
    defaults export "$bundle_id" "$aside/preferences.plist"
    [[ -f "$src/preferences.plist" ]] && defaults import "$bundle_id" "$src/preferences.plist"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
    echo "Restored. Open Browsa when ready (it's the backed-up app, on the system WebKit)."
    ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
