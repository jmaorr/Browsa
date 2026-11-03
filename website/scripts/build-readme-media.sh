#!/bin/zsh
# Turns the site's clips into the animated WebPs in the README, which can't play video files.
# Usage: website/scripts/build-readme-media.sh
set -e
M=${0:A:h}/../public/media
O=${0:A:h}/../../docs/media
mkdir -p $O

anim() {
  local name=$1 vf=$2 TMP=$(mktemp -d)
  ffmpeg -v error -y -i $M/$name.mp4 -vf "fps=20,$vf" $TMP/%04d.png
  img2webp -loop 0 -lossy -q 68 -m 4 -d 50 $TMP/*.png -o $O/$name.webp >/dev/null 2>&1
}

anim sidebar "scale=640:-2"
anim spaces "scale=640:-2"
anim reader "scale=640:-2"
anim suggest "scale=640:-2"
anim grid "scale=320:-2"
anim gutter "scale=200:-2"
