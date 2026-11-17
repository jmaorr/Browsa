#!/bin/bash
# encode.sh <scene dir> <name> <poster frame>: frames → public/media/whats-new/<name>.mp4 and .webp
set -e; d="$1"; out="$(dirname "$0")/../../../public/media/whats-new"
ffmpeg -v error -y -framerate 30 -i "$d/frames/%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 22 -preset slow -movflags +faststart "$out/$2.mp4"
ffmpeg -v error -y -i "$d/frames/$3.png" -quality 82 "$out/$2.webp"
ls -la "$out/$2.mp4" "$out/$2.webp"
