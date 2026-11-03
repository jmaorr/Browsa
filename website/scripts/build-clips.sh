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

# plain <name> <source> <filter> <start> <length>: for takes that end where they started.
plain() {
  ffmpeg -v error -y -i $R/$2.mp4 -vf "fps=60,trim=$4:$(( $4 + $5 )),setpts=PTS-STARTPTS,$3,setsar=1" $ENC $O/$1.mp4
  poster $1
}

# join <name> <source> <filter> <a> <b> <c> <d>: keeps a to b and c to d, cutting a still hold.
join() {
  ffmpeg -v error -y -i $R/$2.mp4 -filter_complex \
    "[0:v]fps=60,$3,setsar=1,split[x][y];[x]trim=$4:$5,setpts=PTS-STARTPTS[a];[y]trim=$6:$7,setpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=1,format=yuv420p" \
    $ENC $O/$1.mp4
  poster $1
}

# dissolve <name> <source> <start> <length> <filter>: the last 0.5s dissolves into the opening
# frames, which are held still in every source, so the loop has no visible jump.
dissolve() {
  local name=$1 src=$2 ss=$3 t=$4 vf=$5
  # Trimming after fps, not seeking first: these captures have no frames during a hold, so a seek
  # would lose the opening stillness.
  ffmpeg -v error -y -i $R/$src.mp4 -filter_complex \
    "[0:v]fps=60,$vf,setsar=1,split[x][y];[x]trim=$ss:$(( ss + t )),setpts=PTS-STARTPTS[a];[y]trim=$ss:$(( ss + 0.6 )),setpts=PTS-STARTPTS[b];[a][b]xfade=transition=fade:duration=0.5:offset=$(( t - 0.5 )),format=yuv420p" \
    $ENC $O/$name.mp4
  poster $name
}

plain sidebar  footage/c2_sidebar  "scale=1320:-2" 2.6 5.0
plain spaces   footage/c2_space    "scale=1320:-2" 3.2 3.8
plain suggest  footage/c3_suggest  "scale=1320:-2" 3.0 5.85
join  reader   footage/c2_reader   "scale=1320:-2" 2.7 7.0 15.3 16.25
plain grid     footage/c2_grid     "scale=760:-2" 2.9 3.1
# Close on the gutter, so the download ring is the subject and the address pill stays out of shot.
dissolve gutter web-clips/gutter-download 0 5.2 "crop=248:560:1150:620,scale=496:-2"
dissolve hero     web-clips/hero-alt 0 12.7 "scale=1760:-2"
dissolve linear   footage/f6_linear 3.5 5.2 "scale=760:-2"
dissolve portrait footage/c4_portrait 2.6 5.1 "scale=960:-2"

poster suggest 3.2
poster reader 3.2
poster grid 1.8
poster gutter 3.6

# The page inside the live layouts section: the wide layout from the sidebar still, the narrow one from the closed still.
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=1726:1880:866:60,scale=1200:-2" -update 1 $TMP/p.png
cwebp -quiet -q 78 $TMP/p.png -o $O/page-wide.webp
ffmpeg -v error -y -i $R/web-clips/still-closed-linear.png -vf "crop=1130:1760:0:0,scale=760:-2" -update 1 $TMP/p.png
cwebp -quiet -q 78 $TMP/p.png -o $O/page-narrow.webp
# The sidebar's real contents, split so the space icons can stay at the bottom at any height.
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=855:1300:0:0" -update 1 $TMP/p.png
cwebp -quiet -q 82 $TMP/p.png -o $O/sidebar-top.webp
ffmpeg -v error -y -i $R/web-clips/still-open-sidebar.png -vf "crop=855:176:0:1830" -update 1 $TMP/p.png
cwebp -quiet -q 82 $TMP/p.png -o $O/sidebar-bottom.webp
