#!/usr/bin/env bash
# Stop offering anything on a channel: bash tools/unpublish.sh <channel>
# Removes the channel's update.json (projectors then find no manifest and do nothing). APKs stay for the record.
set -euo pipefail
REPO=lumenexx/vibe-updates
CHANNEL="${1:?usage: unpublish.sh <channel>}"
[[ "$CHANNEL" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "bad channel" >&2; exit 1; }
gh release delete-asset "$CHANNEL" update.json -R "$REPO" --yes
code="$(curl -s -o /dev/null -w '%{http_code}' -L "https://github.com/$REPO/releases/download/$CHANNEL/update.json")"
echo "channel $CHANNEL: update.json now answers HTTP $code (404 = nothing offered)"
