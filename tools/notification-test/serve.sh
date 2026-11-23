#!/bin/sh
# Serves the notification test page on localhost (a secure context) and opens it in Browsa.
# Usage: tools/notification-test/serve.sh [path to Browsa.app]
cd "$(dirname "$0")" || exit 1
APP="${1:-$HOME/Applications/Browsa.app}"
python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 1
open -a "$APP" http://localhost:8765/
echo "Serving on http://localhost:8765 (stop with: kill $!)"
