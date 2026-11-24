#!/bin/zsh
# Checks that Browsa's YouTube ad blocking still lets videos play. See README.md.
#
#   tools/youtube-ad-check/run.sh [path/to/ads.json] [--verbose]
#
# Builds a small harness from the app's own YouTubeAds.swift and YouTubeAdRules.swift, runs each case
# in a fresh muted offscreen web view, and prints a table. Exits non-zero if a case that should pass fails.
set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
sources=$repo/Packages/BrowserKit/Sources
ads="" verbose=""
for a in "$@"; do
  case $a in
    --verbose) verbose=--verbose ;;
    *) ads=$a ;;
  esac
done

work=${TMPDIR:-/tmp}/youtube-ad-check
mkdir -p $work
bin=$work/youtube-ad-check
echo "Building from $sources …"
swiftc -swift-version 5 -O -o $bin \
  $here/main.swift \
  $sources/WebKitEngine/YouTubeAds.swift \
  $sources/BrowserCore/YouTubeAdRules.swift \
  -framework AppKit -framework WebKit

export STARTER_LIST=$sources/BrowserCore/Resources/blocklist.json
common=(--store $work/rules)
[[ -n $ads ]] && common+=(--ads $ads)
[[ -n $verbose ]] && common+=($verbose)

# name | expected (pass/known) | arguments. Loads are timed from the start of the page load, clicks from the click.
cases=(
  "direct|pass|--url https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  "repeat|pass|--url https://www.youtube.com/watch?v=dQw4w9WgXcQ --repeat"
  "search-click|pass|--url https://www.youtube.com/results?search_query=veritasium --click results"
  "related-click|pass|--url https://www.youtube.com/watch?v=dQw4w9WgXcQ --click related"
  "playlist-mix|pass|--url https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&start_radio=1"
  "mix-next|known|--url https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&start_radio=1 --next --nexts 2"
  "playlist-next|pass|--url https://www.youtube.com/watch?v=PUX1YnmGytM&list=PL0NlNYU99BSMfNcGaEWqBWAh7vOtSzUid&index=1 --next --nexts 2"
  "search-mix|known|--url https://www.youtube.com/results?search_query=rick+astley+mix --click mix"
)

click_limit=6 load_limit=8
failed=0
rows=()
for c in $cases; do
  name=${c%%|*}; rest=${c#*|}; expected=${rest%%|*}; params=${rest#*|}
  echo "Running $name …"
  for try in 1 2 3; do   # again if the page gave nothing to click, or YouTube served no ad (nothing tested)
    out=$($bin --case $name ${=params} $common 2>/dev/null | tee /dev/stderr | grep '^RESULT' | tail -1 || true)
    [[ $out == *error:no_video_to_click* || ( $out != *error:* && $out != *ads-cut* && $out != *server-wait* ) ]] || break
  done
  secs=$(echo $out | awk '{print $3}'); flags=$(echo $out | awk '{print $4}')
  [[ -z $out ]] && secs="-" flags="no-result"
  limit=$load_limit; [[ $params == *--click* || $params == *--next* ]] && limit=$click_limit
  if [[ $secs != "-" && $flags != *ad-showing* && $flags != *-lost* && $flags != *next-stuck* ]] && (( secs <= limit )); then
    verdict=PASS
    [[ $flags == *ads-cut* || $flags == *server-wait* ]] || verdict="PASS (no ad served)"
  elif [[ $expected == known ]]; then
    verdict="FAIL (known)"
  else
    verdict=FAIL; failed=1
  fi
  rows+=("$name|$secs|$flags|$verdict")
done

echo
printf "%-15s %-10s %-50s %s\n" "case" "play (s)" "flags" "result"
printf "%-15s %-10s %-50s %s\n" "---------------" "--------" "------------------------------------------------" "------"
for r in $rows; do
  IFS='|' read -r n s f v <<< $r
  printf "%-15s %-10s %-50s %s\n" $n $s $f $v
done
echo
echo "PASS: plays within ${click_limit}s of a click or Next (${load_limit}s of a page load), with no ad showing,"
echo "and on a playlist the playlist is kept (list-ok; next-ok: every Next opened the playlist's next item)."
echo "Flags: ads-cut = YouTube sent an ad and the script took it out; server-wait-Ns = the stream server asked"
echo "the player to wait N s (the cut ad's length); ad-showing = an ad played; ad-data-left = ads got past the script;"
echo "list-lost / next-lost = the playlist was dropped; next-stuck = Next didn't play the playlist's next item."
echo "\"no ad served\" means YouTube sent no ad this time, so that case proves nothing: run again."
exit $failed
