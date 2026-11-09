#!/bin/zsh
# Builds Browsa for Mac (Release, com.orriginal.browsa) and installs it as /Applications/Browsa.app.
#
#   tools/install-mac.sh              # latest origin/main
#   tools/install-mac.sh <git-ref>    # any branch, tag or commit, e.g. origin/claude/some-branch
#
# Builds from a clean export of the ref, so it doesn't matter which branch this checkout (or any
# worktree) is on, or what's uncommitted in it. Website data, sign-ins, tabs and extensions live
# in the sandbox container for com.orriginal.browsa, which reinstalling never touches. Xcode's
# Run button builds "Browsa Dev" (com.orriginal.browsa.dev) with its own container instead.
set -euo pipefail

repo="${0:A:h:h}"
ref="${1:-origin/main}"
work="$HOME/Library/Caches/com.orriginal.browsa.install"
src="$work/src"
app="/Applications/Browsa.app"
bundle_id="com.orriginal.browsa"

echo "==> Fetching $ref"
if [[ "$ref" == origin/* ]]; then
  for attempt in 1 2 3 4; do
    git -C "$repo" fetch --quiet origin "${ref#origin/}" && break
    [[ $attempt == 4 ]] && { echo "fetch failed" >&2; exit 1; }
    sleep $((2 ** attempt))
  done
fi
commit=$(git -C "$repo" rev-parse --short "$ref^{commit}")

echo "==> Exporting $ref ($commit)"
rm -rf "$work/export" && mkdir -p "$work/export" "$src"
git -C "$repo" archive "$commit" | tar -x -C "$work/export"
# Copy only files that changed, keeping the rest's timestamps so the build stays incremental.
rsync -rlc --delete --exclude Browsa.xcodeproj "$work/export/" "$src/"
rm -rf "$work/export"

echo "==> Building Browsa (Release)"
cd "$src"
xcodegen generate --quiet
xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$work/DerivedData" \
  -allowProvisioningUpdates -quiet build
built="$work/DerivedData/Build/Products/Release/Browsa.app"
[[ "$(defaults read "$built/Contents/Info.plist" CFBundleIdentifier)" == "$bundle_id" ]] \
  || { echo "built app doesn't have the bundle ID $bundle_id" >&2; exit 1; }

# Any running copy with this ID shares the container (an old Xcode build too), so it quits first.
running() { [[ "$(osascript -e "application id \"$bundle_id\" is running")" == true ]]; }
if running; then
  echo "==> Quitting the running Browsa (tabs are saved on quit)"
  osascript -e "tell application id \"$bundle_id\" to quit" || true
  for _ in {1..60}; do running || break; sleep 0.25; done
  running && { echo "Browsa didn't quit; quit it and run this again" >&2; exit 1; }
fi

echo "==> Installing $app"
rm -rf "$app"
ditto "$built" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
open "$app"
echo "==> Browsa $commit installed and running"
