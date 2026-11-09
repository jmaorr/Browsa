#!/bin/zsh
# Builds a Browsa for Mac release: Developer ID signed, notarised, stapled, zipped, and added to a
# Sparkle appcast. Publishes nothing; it prints what to upload. See docs/mac-releases.md.
#
#   tools/release-mac.sh <version> [git-ref]     # e.g. tools/release-mac.sh 1.0.1 origin/main
#
# Signing and notarisation go through the Xcode account (team UAU4449Y7J) with a cloud-managed
# Developer ID certificate, so no certificate, app-specific password or notarytool profile is needed.
# The Sparkle EdDSA private key is read from the login keychain (made once with generate_keys).
set -euo pipefail

version="${1:?usage: tools/release-mac.sh <version> [git-ref]}"
ref="${2:-origin/main}"
repo="${0:A:h:h}"
team="UAU4449Y7J"
bundle_id="com.orriginal.browsa"
# Where zips and appcast.xml collect between releases. generate_appcast reads every zip here, so
# keep old ones: they give the appcast its history and Sparkle its deltas.
releases="${BROWSA_RELEASES_DIR:-$HOME/Developer/Browsa/releases/mac}"
download_prefix="https://browsa.app/mac/releases/"
work="$HOME/Library/Caches/com.orriginal.browsa.release"
src="$work/src"
derived="$work/DerivedData"
archive="$work/Browsa.xcarchive"

[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "version should look like 1.2 or 1.2.3" >&2; exit 1; }
[[ -e "$releases/Browsa-$version.zip" ]] && { echo "$releases/Browsa-$version.zip already exists" >&2; exit 1; }

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
rm -rf "$src" "$archive" "$work/upload" "$work/notarized" && mkdir -p "$src" "$releases"
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
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$export_options" \
  -exportPath "$work/upload" -allowProvisioningUpdates -quiet

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

echo "==> Zipping"
zip="$releases/Browsa-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
notes="$repo/docs/release-notes/mac/$version.md"
[[ -f "$notes" ]] && cp "$notes" "$releases/Browsa-$version.md"

echo "==> Updating the appcast"
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_appcast" --download-url-prefix "$download_prefix" --embed-release-notes \
  --maximum-deltas 3 "$releases"

echo
echo "==> Browsa $version ($build, $commit) is ready in $releases"
echo "    Upload to $download_prefix: Browsa-$version.zip and any new *.delta files"
echo "    Then publish appcast.xml at https://browsa.app/mac/appcast.xml (last, so it never points at a missing file)"
