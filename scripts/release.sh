#!/bin/bash
# Usage: scripts/release.sh 1.2.0 "What changed"
# Bumps VERSION, commits, and pushes a signed-off tag; GitHub Actions builds, signs and
# publishes the release, and every installed copy picks it up through the in-app updater.
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-ContactMirror $NEW}"
echo "$NEW" > VERSION
git add VERSION
git commit -m "Release $NEW"
git tag -a "v$NEW" -m "$NOTES"
git push origin HEAD "v$NEW"
echo "Pushed v$NEW – watch the build with: gh run watch"
