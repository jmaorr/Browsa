#!/bin/zsh
# Builds a Browsa for Mac release: Developer ID signed, notarised, stapled, zipped, and added to a
# Sparkle appcast. Publishes nothing; it prints what to upload. See docs/mac-releases.md.
#
#   tools/release-mac.sh <version> [git-ref]           # e.g. tools/release-mac.sh 1.0.1 origin/main
#   tools/release-mac.sh --local <version> [git-ref]   # local only: archive, bundle, Developer ID export to disk,
#                                                      # checks and sizes. Nothing goes to the notary service, and
#                                                      # no zip, DMG or appcast lands in the releases folder.
#
# Browsa's own WebKit (call audio, Spike/CallAudio/webkit/BUNDLING.md) goes inside the app only when asked:
#   BROWSA_BUNDLE_WEBKIT="26=<webkit build folder> 27=<webkit build folder>" tools/release-mac.sh ...
# with release WebKit builds from Spike/CallAudio/webkit/build-release-webkit.sh. Without it, the app is as before.
#
# Signing and notarisation go through the Xcode account (team UAU4449Y7J) with a cloud-managed
# Developer ID certificate, so no certificate, app-specific password or notarytool profile is needed.
# The Sparkle EdDSA private key is read from the login keychain (made once with generate_keys).
set -euo pipefail

local_only=0
[[ "${1:-}" == --local ]] && { local_only=1; shift; }
version="${1:?usage: tools/release-mac.sh [--local] <version> [git-ref]}"
ref="${2:-origin/main}"
repo="${0:A:h:h}"
team="UAU4449Y7J"
bundle_id="com.orriginal.browsa"
# Where zips, DMGs and appcast.xml collect between releases. generate_appcast reads every zip
# here, so keep old ones: they give the appcast its history and Sparkle its deltas. DMGs go in
# dmg/ underneath, where generate_appcast doesn't look (it would take them for duplicate updates).
releases="${BROWSA_RELEASES_DIR:-$HOME/Developer/Browsa/releases/mac}"
download_prefix="https://browsa.app/mac/releases/"
work="$HOME/Library/Caches/com.orriginal.browsa.release"
(( local_only )) && work="$work-local"
bundle_webkit=(${=BROWSA_BUNDLE_WEBKIT:-})
src="$work/src"
derived="$work/DerivedData"
archive="$work/Browsa.xcarchive"

[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "version should look like 1.2 or 1.2.3" >&2; exit 1; }
(( local_only )) || [[ ! -e "$releases/Browsa-$version.zip" ]] || { echo "$releases/Browsa-$version.zip already exists" >&2; exit 1; }

echo "==> Fetching $ref"
if [[ "$ref" == origin/* ]]; then
  for attempt in 1 2 3 4; do
    git -C "$repo" fetch --quiet origin "${ref#origin/}" && break
    [[ $attempt == 4 ]] && { echo "fetch failed" >&2; exit 1; }
    sleep $((2 ** attempt))
  done
fi
commit=$(git -C "$repo" rev-parse --short "$ref^{commit}")
# Sparkle compares CFBundleVersion, so it has to grow with every release: the commit count does.
build=$(git -C "$repo" rev-list --count "$commit")

echo "==> Exporting $ref ($commit) as $version ($build)"
rm -rf "$src" "$archive" "$work/upload" "$work/notarized" "$work/export" && mkdir -p "$src"
(( local_only )) || mkdir -p "$releases"
git -C "$repo" archive "$commit" | tar -x -C "$src"

echo "==> Archiving"
cd "$src"
xcodegen generate --quiet
xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$archive" \
  -allowProvisioningUpdates -quiet \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" BROWSA_UPDATES=YES \
  archive

plist="$archive/Products/Applications/Browsa.app/Contents/Info.plist"
[[ "$(defaults read "$plist" CFBundleIdentifier)" == "$bundle_id" ]] || { echo "wrong bundle ID" >&2; exit 1; }
[[ "$(defaults read "$plist" BrowsaUpdates)" == "YES" ]] || { echo "updates aren't switched on" >&2; exit 1; }

if (( ${#bundle_webkit} )); then
  echo "==> Bundling Browsa's WebKit (${bundle_webkit[*]})"
  archived_app="$archive/Products/Applications/Browsa.app"
  # Sign like the archive did (its identity); the Developer ID export re-signs everything afterwards.
  identity=$(codesign -dvv "$archived_app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  [[ -n "$identity" ]] || { echo "can't tell how the archive was signed" >&2; exit 1; }
  "$src/tools/mac-bundle-webkit.sh" "$archived_app" "$identity" "${bundle_webkit[@]}"
  # WebKit's dSYMs with the app's, for crash reports.
  mkdir -p "$archive/dSYMs" && cp -cR "$archive/Products/Applications/dSYMs/"* "$archive/dSYMs/" && rm -rf "$archive/Products/Applications/dSYMs"
fi

if (( local_only )); then
  echo "==> Signing with Developer ID, to disk only (nothing goes to the notary service)"
  export_options="$work/ExportOptions.plist"
  cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$export_options" \
    -exportPath "$work/export" -allowProvisioningUpdates > "$work/export.log" 2>&1 \
    || { tail -20 "$work/export.log" >&2; echo "export failed (log: $work/export.log)" >&2; exit 1; }
  app="$work/export/Browsa.app"
  "$src/tools/mac-check-release.sh" "$app"
  zip="$work/Browsa-$version.zip"
  rm -f "$zip" && ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  echo
  echo "==> Local build of Browsa $version ($build, $commit), not notarised: $app"
  echo "    on disk $(du -sh "$app" | cut -f1), zipped $(du -h "$zip" | cut -f1) ($zip)"
  exit 0
fi

echo "==> Signing with Developer ID and sending to Apple's notary service"
export_options="$work/ExportOptions.plist"
cat > "$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
EOF
# Stop here if the upload didn't go through: xcodebuild has printed "EXPORT FAILED" after a timeout without the
# script noticing, which then waited half an hour for a notarisation that was never requested.
export_status=0
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$export_options" \
  -exportPath "$work/upload" -allowProvisioningUpdates > "$work/upload.log" 2>&1 || export_status=$?
{ grep -v 'Progress [0-9]*%' "$work/upload.log" || true; } | tail -20
if (( export_status != 0 )) || grep -q "EXPORT FAILED" "$work/upload.log" || ! grep -q "EXPORT SUCCEEDED" "$work/upload.log"; then
  echo "The upload to Apple's notary service failed (exit $export_status, log: $work/upload.log). Stopping." >&2
  exit 1
fi

echo "==> Waiting for notarisation (usually a few minutes)"
for attempt in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$work/notarized" >/dev/null 2>&1; then
    break
  fi
  [[ $attempt == 60 ]] && { echo "not notarised after 30 minutes; check Xcode's Organizer" >&2; exit 1; }
  sleep 30
done
app="$work/notarized/Browsa.app"
xcrun stapler validate -q "$app"
spctl --assess --type execute "$app" || { echo "Gatekeeper rejected the notarised app" >&2; exit 1; }
"$src/tools/mac-check-release.sh" "$app"

echo "==> Zipping"
zip="$releases/Browsa-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
notes="$repo/docs/release-notes/mac/$version.md"
[[ -f "$notes" ]] && cp "$notes" "$releases/Browsa-$version.md"

echo "==> Making the DMG for first downloads"
# Drag-to-Applications window: background art in Mac/Distribution (600×360 pt, @1x and @2x in one
# TIFF), the app on the left, the Applications link over the drawn folder. create-dmg lays the
# window out by scripting Finder, so the first run asks to let the terminal control Finder.
# The DMG isn't signed or notarised itself; the app inside is, and its ticket is stapled.
command -v create-dmg >/dev/null || { echo "create-dmg is missing: brew install create-dmg" >&2; exit 1; }
mkdir -p "$releases/dmg"
dmg="$releases/dmg/Browsa-$version.dmg"
dmg_stage="$work/dmg" && rm -rf "$dmg_stage" && mkdir -p "$dmg_stage" && ditto "$app" "$dmg_stage/Browsa.app"
create-dmg --volname "Browsa" --background "$src/Mac/Distribution/dmg-background.tiff" \
  --window-pos 200 120 --window-size 600 400 --icon-size 100 \
  --icon "Browsa.app" 175 190 --hide-extension "Browsa.app" --app-drop-link 425 190 \
  --no-internet-enable "$dmg" "$dmg_stage" >/dev/null
mount=$(mktemp -d)
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" >/dev/null
layout_ok=1
for f in .DS_Store .background/dmg-background.tiff Applications Browsa.app; do
  [[ -e "$mount/$f" ]] || { echo "DMG is missing $f" >&2; layout_ok=0; }
done
spctl --assess --type execute "$mount/Browsa.app" || layout_ok=0
hdiutil detach "$mount" -quiet
[[ $layout_ok == 1 ]] || { echo "DMG check failed; don't ship it" >&2; exit 1; }
# The site's Download button always points at Browsa.dmg, the newest build.
cp "$dmg" "$releases/dmg/Browsa.dmg"

echo "==> Updating the appcast"
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_appcast" --download-url-prefix "$download_prefix" --embed-release-notes \
  --maximum-deltas 3 "$releases"

echo
echo "==> Browsa $version ($build, $commit) is ready in $releases"
echo "    Upload to $download_prefix: Browsa-$version.zip, any new *.delta files, and from dmg/"
echo "    Browsa-$version.dmg and Browsa.dmg"
echo "    Then publish appcast.xml at https://browsa.app/mac/appcast.xml (last, so it never points at a missing file)"
