#!/bin/zsh
# Trims raw simulator captures into the site's looping clips and posters.
# Usage: BROWSA_CAPTURES=path/to/captures website/scripts/build-clips.sh
set -e
R=${BROWSA_CAPTURES:-$HOME/Developer/BrowsaSizzle}
O=${0:A:h}/../public/media
ENC=(-an -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart)

TMP=$(mktemp -d)
# An optional time picks a telling frame, for visitors who have clips paused.
poster() {
  ffmpeg -v error -y -ss ${2:-0} -i $O/$1.mp4 -frames:v 1 -update 1 $TMP/p.png
  cwebp -quiet -q 80 $TMP/p.png -o $O/$1.webp
}

# plain <name> <source> <filter> [length]: for captures that end where they started.
plain() {
  ffmpeg -v error -y -i $R/$2.mp4 ${4:+-t} $4 -vf "$3,setsar=1" $ENC $O/$1.mp4
  poster $1
}

# dissolve <name> <source> <start> <length> <filter>: the last 0.5s dissolves into the opening
# frames, which are held still in every source, so the loop has no visible jump.
dissolve() {
  local name=$1 src=$2 ss=$3 t=$4 vf=$5
  ffmpeg -v error -y -ss $ss -t $t -i $R/$src.mp4 -ss $ss -t 0.6 -i $R/$src.mp4 -filter_complex \
    "[0:v]fps=60,$vf,setsar=1[a];[1:v]fps=60,$vf,setsar=1[b];[a][b]xfade=transition=fade:duration=0.5:offset=$(( t - 0.5 )),format=yuv420p" \
    $ENC $O/$name.mp4
  poster $name
}

plain sidebar  web-clips/sidebar-toggle "scale=1320:-2"
plain spaces   web-clips/space-swipe    "scale=1320:-2"
plain suggest  web-clips/newtab-suggest "scale=1320:-2"
plain reader   web-clips/reader         "scale=1320:-2"
plain grid     web-clips/tab-grid       "scale=760:-2" 3.5
# Close on the gutter, so the download ring is the subject and the address pill stays out of shot.
dissolve gutter web-clips/gutter-download 0 5.2 "crop=248:560:1150:620,scale=496:-2"
dissolve hero     web-clips/hero-alt 0 12.7 "scale=1760:-2"
dissolve linear   footage/f6_linear 3.5 5.2 "scale=760:-2"
dissolve portrait footage/p6_scroll 2.8 4.4 "scale=960:-2"

poster suggest 3.6
poster reader 3.2
poster grid 1.8
poster gutter 3.6

# The page inside the live layouts section: the wide layout from the sidebar still, the narrow one from the closed still.
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=1730:1880:862:60,scale=1200:-2" -update 1 $TMP/p.png
cwebp -quiet -q 78 $TMP/p.png -o $O/page-wide.webp
ffmpeg -v error -y -i $R/web-clips/still-closed-linear.png -vf "crop=1130:1760:0:0,scale=760:-2" -update 1 $TMP/p.png
cwebp -quiet -q 78 $TMP/p.png -o $O/page-narrow.webp
# The sidebar's real contents, split so the space icons can stay at the bottom at any height.
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=855:1300:0:0" -update 1 $TMP/p.png
cwebp -quiet -q 82 $TMP/p.png -o $O/sidebar-top.webp
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=855:176:0:1830" -update 1 $TMP/p.png
cwebp -quiet -q 82 $TMP/p.png -o $O/sidebar-bottom.webp
