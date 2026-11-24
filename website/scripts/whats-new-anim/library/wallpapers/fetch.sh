#!/bin/sh
# Stand-in wallpapers for the Library clips, from Pexels (free to use, pexels.com/license).
# Not committed: run this once before rendering. Swap in our own photos by replacing the files.
cd "$(dirname "$0")"
for pair in agent-pack:11334345 live-folders:376368 boosts:38409470 space-routing:9674393 notes:2504713 agents:40619276 radar:1819660 privacy:7573616; do
  name=${pair%%:*}; id=${pair##*:}
  [ -f "$name.jpg" ] || curl -sfL -o "$name.jpg" "https://images.pexels.com/photos/$id/pexels-photo-$id.jpeg?auto=compress&cs=tinysrgb&w=2000"
done
