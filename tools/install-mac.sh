#!/bin/zsh
# Builds Browsa for Mac (Release, com.orriginal.browsa) and installs it as ~/Applications/Browsa.app
# (or BROWSA_INSTALL_PATH).
#
#   tools/install-mac.sh              # latest origin/main
#   tools/install-mac.sh <git-ref>    # any branch, tag or commit, e.g. origin/claude/some-branch
#   tools/install-mac.sh --patched-webkit [<git-ref>]
#                                     # signed so it may run on Browsa's own WebKit build
#                                     # (Mac/BrowsaLocalWebKit.entitlements; see Mac/Sources/PatchedWebKit.swift)
#
# BROWSA_DEVELOPER_ID=1 signs the install with the Developer ID, as releases are (archive, then a Developer ID
# export to disk through Xcode's cloud-managed certificate; nothing is notarised or uploaded). 1Password trusts a
# browser added under Settings › Browser only when it's Developer ID or App Store signed, so its desktop app unlock
# needs this. Updates stay off.
#
# Builds from a clean export of the ref, so it doesn't matter which branch this checkout (or any
# worktree) is on, or what's uncommitted in it. Website data, sign-ins, tabs and extensions live
# in the sandbox container for com.orriginal.browsa, which reinstalling never touches. Xcode's
# Run button builds "Browsa Dev" (com.orriginal.browsa.dev) with its own container instead.
set -euo pipefail

repo="${0:A:h:h}"
patched_webkit=0
if [[ "${1:-}" == --patched-webkit ]]; then patched_webkit=1; shift; fi
ref="${1:-origin/main}"
work="$HOME/Library/Caches/com.orriginal.browsa.install"
src="$work/src"
# ~/Applications, always: /Applications needs admin rights on some Macs, and one fixed
# place means a single copy. Launch Services and the default-browser setting treat it the same.
app="${BROWSA_INSTALL_PATH:-$HOME/Applications/Browsa.app}"
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
extra=()
# The local daily also gets the development-only call recording switch (Settings › Audio), never in releases.
(( patched_webkit )) && extra=(CODE_SIGN_ENTITLEMENTS=Mac/BrowsaLocalWebKit.entitlements 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BROWSA_CALL_RECORDING')
# A fresh product each time: an incremental build keeps whatever an earlier build embedded (Chromium, after call
# tabs were removed).
rm -rf "$work/DerivedData/Build/Products/Release/Browsa.app"
if [[ "${BROWSA_DEVELOPER_ID:-0}" == 1 ]]; then
  archive="$work/Browsa.xcarchive"
  rm -rf "$archive" "$work/developer-id"
  xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" -archivePath "$archive" \
    -allowProvisioningUpdates -quiet BROWSA_UPDATES=NO archive "${extra[@]}"
  cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>UAU4449Y7J</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  echo "==> Signing with Developer ID, to disk only"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
    -exportPath "$work/developer-id" -allowProvisioningUpdates > "$work/export.log" 2>&1 \
    || { tail -20 "$work/export.log" >&2; echo "Developer ID export failed (log: $work/export.log)" >&2; exit 1; }
  built="$work/developer-id/Browsa.app"
  # Read into a variable first: with pipefail, grep -q closing the pipe early fails the pipeline.
  signing=$(codesign -dvv "$built" 2>&1)
  [[ "$signing" == *"Authority=Developer ID Application"* ]] \
    || { echo "exported app isn't Developer ID signed" >&2; exit 1; }
else
  xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$work/DerivedData" \
    -allowProvisioningUpdates -quiet build "${extra[@]}"
  built="$work/DerivedData/Build/Products/Release/Browsa.app"
fi
if (( patched_webkit )); then
  codesign -d --entitlements - "$built" 2>/dev/null | grep -q allow-dyld-environment-variables \
    || { echo "built app isn't signed for Browsa's WebKit (Mac/BrowsaLocalWebKit.entitlements missing from the ref?)" >&2; exit 1; }
fi
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
mkdir -p "${app:h}"
rm -rf "$app"
ditto "$built" "$app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Old Xcode builds with the same ID stay registered and can catch links or the default-browser
# setting, so Launch Services forgets every copy but this one. (Their files aren't touched.)
swift -e "import AppKit; for u in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: \"$bundle_id\") { print(u.path) }" 2>/dev/null |
  while IFS= read -r other; do [[ "$other" == "$app" ]] || "$lsregister" -u "$other" 2>/dev/null || true; done
"$lsregister" -f "$app"
open "$app"
echo "==> Browsa $commit installed and running"
