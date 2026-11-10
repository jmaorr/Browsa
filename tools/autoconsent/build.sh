#!/usr/bin/env bash
# Rebuilds Packages/BrowserKit/Sources/BrowserCore/Resources/autoconsent.js from DuckDuckGo's
# autoconsent package (MPL-2.0). Run from the repo root: tools/autoconsent/build.sh [version]
set -euo pipefail
VERSION="${1:-17.2.0}"
WORK=.autoconsent
rm -rf "$WORK" && mkdir -p "$WORK"
curl -sSfL "https://registry.npmjs.org/@duckduckgo/autoconsent/-/autoconsent-$VERSION.tgz" | tar xz -C "$WORK"
OUT=Packages/BrowserKit/Sources/BrowserCore/Resources/autoconsent.js
{
  echo "/*! DuckDuckGo autoconsent $VERSION, MPL-2.0: https://github.com/duckduckgo/autoconsent */"
  npx --yes esbuild@0.25.0 tools/autoconsent/entry.ts --bundle --format=iife --minify --target=safari16 --log-level=warning
} > "$OUT"
node tools/autoconsent/frame-gate.mjs "$WORK/package" Packages/BrowserKit/Sources/BrowserCore/Resources/autoconsent-frames.js
cp "$WORK/package/LICENSE" Packages/BrowserKit/Sources/BrowserCore/Resources/autoconsent-LICENSE.txt
rm -rf "$WORK"
echo "Wrote $OUT ($(wc -c < "$OUT") bytes)"
