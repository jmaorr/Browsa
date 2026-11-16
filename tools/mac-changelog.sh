#!/bin/bash
# Lists what changed for Mac users between two refs, as raw material for release notes.
#
#   tools/mac-changelog.sh <last-release-ref> [release-ref]
#
# <last-release-ref>: the commit the previous release was built from (see docs/release-notes/mac/README.md).
# [release-ref]: what the new release is built from; defaults to origin/main.
#
# Prints the merged PRs first, then every commit that touched the Mac app or the shared packages, with its
# message body, oldest first. Commits that only touch iOS (App/), the website, docs, tools, spikes or CI are
# left out. Read the bodies, not just the titles: they say what the user sees.
set -euo pipefail
from=${1:?usage: tools/mac-changelog.sh <last-release-ref> [release-ref]}
to=${2:-origin/main}

echo "# Changes from $(git rev-parse --short "$from") to $(git rev-parse --short "$to")"
echo
echo "## Merged pull requests"
git log --first-parent --reverse --format='- %s' "$from..$to"
echo
echo "## Mac commits"
git log --no-merges --reverse --format='### %h %s%n%n%b' "$from..$to" -- Mac Packages project.yml \
  | grep -v -e '^Co-Authored-By:' -e '^Claude-Session:'
