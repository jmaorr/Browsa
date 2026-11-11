#!/bin/sh
# How many Macs check for updates, and how many downloads start, from the counts the Worker keeps
# in Workers Analytics Engine (dataset browsa_usage). No IPs or IDs are stored, so these are plain
# daily totals. Analytics Engine keeps three months.
#
#   CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… scripts/usage.sh [days]
#
# The token needs Account › Account Analytics › Read.
set -eu
days="${1:-30}"
case "$days" in *[!0-9]*|'') echo "usage: scripts/usage.sh [days]" >&2; exit 1;; esac
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}" "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"

query() {
  curl -fsS "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics_engine/sql" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" --data-binary "$1 FORMAT TabSeparatedWithNames"
  echo
}

echo "== Per day (update checks are roughly Macs running Browsa that day)"
query "SELECT toDate(timestamp) AS day,
  SUM(IF(blob1 = 'update-check', _sample_interval, 0)) AS update_checks,
  SUM(IF(blob1 = 'download', _sample_interval, 0)) AS downloads,
  SUM(IF(blob1 = 'update', _sample_interval, 0)) AS updates_installed
  FROM browsa_usage WHERE timestamp > NOW() - INTERVAL '$days' DAY
  GROUP BY day ORDER BY day DESC"

echo "== App versions checking for updates, last 7 days"
query "SELECT blob2 AS version, SUM(_sample_interval) AS checks
  FROM browsa_usage WHERE blob1 = 'update-check' AND timestamp > NOW() - INTERVAL '7' DAY
  GROUP BY version ORDER BY checks DESC"

echo "== Downloads by file, last $days days"
query "SELECT blob2 AS release, SUM(_sample_interval) AS downloads
  FROM browsa_usage WHERE blob1 = 'download' AND timestamp > NOW() - INTERVAL '$days' DAY
  GROUP BY release ORDER BY downloads DESC"
