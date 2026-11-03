#!/bin/sh
# Usage: ./build.sh [output-dir] [entitlements]. Signs with your Apple Development identity and no profile.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
entitlements="${2:-$here/sandbox.entitlements}"
app="$out/BrowsaMacSpike.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macos15.4 -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit -framework WebKit -framework AuthenticationServices -framework Security \
  "$here/Sources/main.swift" -o "$app/Contents/MacOS/BrowsaMacSpike"
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
codesign --force --sign "$identity" --options runtime --entitlements "$entitlements" "$app"
echo "$app"
