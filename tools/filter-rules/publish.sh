#!/usr/bin/env bash
# Builds the rules and uploads them to the R2 bucket behind rules.browsa.app. The manifest goes last,
# so the app never sees a version whose files aren't there yet. Run from this directory, with
# Wrangler logged in or CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID set.
set -euo pipefail
BUCKET="${BUCKET:-browsa-rules}"
WRANGLER="${WRANGLER:-npx --yes wrangler@4}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swift run -c release build-rules "$OUT"
cp LICENSE "$OUT/LICENSE.txt"

put() { # file, content type, cache control
  gzip -9 -c "$OUT/$1" > "$OUT/$1.gz"
  $WRANGLER r2 object put "$BUCKET/v1/$1" --remote --file "$OUT/$1.gz" \
    --content-type "$2" --content-encoding gzip --cache-control "$3"
}

for f in "$OUT"/sources/*.txt; do put "sources/$(basename "$f")" "text/plain; charset=utf-8" "public, max-age=3600"; done
put LICENSE.txt "text/plain; charset=utf-8" "public, max-age=86400"
for f in ads privacy annoyances; do put "$f.json" "application/json" "public, max-age=3600"; done
put manifest.json "application/json" "public, max-age=300"
