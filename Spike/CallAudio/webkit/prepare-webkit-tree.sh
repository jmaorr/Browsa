#!/bin/zsh
# Puts a WebKit source tree at the commit Browsa builds from: upstream WebKit at WEBKIT_BASE plus Browsa's own
# fixes in fixes/ (commits that aren't upstream, so they exist nowhere but here).
#
#   Spike/CallAudio/webkit/prepare-webkit-tree.sh <webkit source tree>     # e.g. ~/Developer/BrowsaWebKit-release
#
# The tree must have no uncommitted changes (webkit.patch and the headers go on afterwards, README.md).
# The result's files match WEBKIT_TREE; its commit hash only matches WEBKIT_COMMIT on the Mac that made the
# fix, which is why build-release-webkit.sh accepts either.
set -euo pipefail
here="${0:A:h}"
tree="${1:?usage: prepare-webkit-tree.sh <webkit source tree>}"
tree="${tree:A}"
base="$(cat "$here/WEBKIT_BASE")"

[[ -z "$(git -C "$tree" status --porcelain -uno)" ]] || { echo "$tree has uncommitted changes" >&2; exit 1; }
git -C "$tree" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$tree" fetch origin "$base"
git -C "$tree" checkout --detach "$base"
git -C "$tree" am "$here"/fixes/*.patch
[[ "$(git -C "$tree" rev-parse 'HEAD^{tree}')" == "$(cat "$here/WEBKIT_TREE")" ]] || { echo "$tree doesn't match WEBKIT_TREE after the fixes" >&2; exit 1; }
echo "==> $tree is at WEBKIT_BASE plus $(ls "$here"/fixes/*.patch | wc -l | tr -d ' ') fix(es); now apply webkit.patch and copy the headers (README.md)"
