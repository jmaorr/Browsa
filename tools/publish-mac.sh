#!/bin/zsh
# Publishes a Mac release made by tools/release-mac.sh to browsa.app: uploads its files to the
# browsa-releases R2 bucket, which the website Worker serves at /mac/appcast.xml and /mac/releases/.
#
#   tools/publish-mac.sh <version>
#
# The appcast goes up last, so installed copies never see an update whose files aren't there yet.
# Browsa.dmg is replaced too, which is what the site's Download button gives new users.
set -euo pipefail

version="${1:?usage: tools/publish-mac.sh <version>}"
repo="${0:A:h:h}"
releases="${BROWSA_RELEASES_DIR:-$HOME/Developer/Browsa/releases/mac}"
bucket="browsa-releases"

zip="$releases/Browsa-$version.zip"
dmg="$releases/dmg/Browsa-$version.dmg"
for f in "$zip" "$dmg" "$releases/appcast.xml"; do
  [[ -f "$f" ]] || { echo "missing $f; run tools/release-mac.sh $version first" >&2; exit 1; }
done
grep -q "Browsa-$version.zip" "$releases/appcast.xml" || { echo "appcast.xml doesn't list $version" >&2; exit 1; }
build=$(unzip -p "$zip" Browsa.app/Contents/Info.plist | plutil -extract CFBundleVersion raw -)

put() {  # put <file> <key> <content-type>
  echo "==> $2"
  (cd "$repo/website" && npx --yes wrangler r2 object put "$bucket/$2" --file "$1" --content-type "$3" --remote >/dev/null)
}

put "$zip" "mac/releases/Browsa-$version.zip" application/zip
for delta in "$releases"/Browsa$build-*.delta(N); do
  put "$delta" "mac/releases/${delta:t}" application/octet-stream
done
put "$dmg" "mac/releases/Browsa-$version.dmg" application/x-apple-diskimage
put "$dmg" "mac/releases/Browsa.dmg" application/x-apple-diskimage
put "$releases/appcast.xml" "mac/appcast.xml" "application/rss+xml; charset=utf-8"

echo "==> Browsa $version ($build) is live: https://browsa.app/mac/appcast.xml"
