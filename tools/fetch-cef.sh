#!/bin/sh
# Fetches the Chromium Embedded Framework (CEF) Browsa's call tabs run on, checks it, and builds its
# C++ wrapper library. Output: .cef/cef in the repo (gitignored), which the Xcode project points at.
# Re-running is a no-op once the pinned version is there.
set -eu
VERSION="156.0.15+gcf671c0+chromium-156.0.8078.80"
NAME="cef_binary_${VERSION}_macosarm64_minimal"
SHA1="bcdd1877edb300b0fb91d8f71c0b14aae256cd0f"
URL="https://cef-builds.spotifycdn.com/$(printf %s "$NAME" | sed 's/+/%2B/g').tar.bz2"

REPO=$(cd "$(dirname "$0")/.." && pwd)
DEST="$REPO/.cef"
CACHE="${CEF_CACHE:-$HOME/Library/Caches/browsa-cef}"
mkdir -p "$DEST" "$CACHE"

if [ -f "$DEST/cef/.version" ] && [ "$(cat "$DEST/cef/.version")" = "$VERSION" ] \
   && [ -f "$DEST/cef/build/libcef_dll_wrapper/Release/libcef_dll_wrapper.a" ]; then
  echo "CEF $VERSION is ready in $DEST/cef"; exit 0
fi

ARCHIVE="$CACHE/$NAME.tar.bz2"
if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 1 "$ARCHIVE" | cut -d' ' -f1)" != "$SHA1" ]; then
  echo "Downloading $NAME (about 130 MB)"
  curl -fL --retry 3 -o "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
GOT=$(shasum -a 1 "$ARCHIVE" | cut -d' ' -f1)
[ "$GOT" = "$SHA1" ] || { echo "Checksum mismatch for $ARCHIVE: $GOT, expected $SHA1" >&2; exit 1; }

rm -rf "$DEST/cef" "$DEST/$NAME"
tar -xjf "$ARCHIVE" -C "$DEST"
mv "$DEST/$NAME" "$DEST/cef"

command -v cmake >/dev/null || { echo "Needs cmake (brew install cmake)" >&2; exit 1; }
cd "$DEST/cef" && mkdir -p build && cd build
cmake -G Xcode -DPROJECT_ARCH=arm64 .. >/dev/null
xcodebuild -project cef.xcodeproj -target libcef_dll_wrapper -configuration Release -quiet
echo "$VERSION" > "$DEST/cef/.version"
echo "CEF $VERSION is ready in $DEST/cef"
