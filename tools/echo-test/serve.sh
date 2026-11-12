#!/bin/sh
# Serves the mic and echo test on http://localhost:8765 (microphones need localhost or https).
# Open that address in each browser you want to compare. Ctrl-C stops it.
cd "$(dirname "$0")" && echo "Open http://localhost:8765 in each browser" && exec python3 -m http.server 8765 --bind 127.0.0.1
