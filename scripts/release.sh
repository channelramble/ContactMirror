#!/bin/bash
# Usage: scripts/release.sh 1.2.0 "What changed"
#
# Builds a universal, signed ContactMirror.app locally and publishes it as a GitHub release.
# Every installed copy then picks it up through the in-app updater.
#
# The signing certificate never leaves this machine. It lives in $SIGNING_DIR
# (default ~/.contactmirror-signing): signing.keychain-db + keychain-password.txt.
# All releases MUST be signed with that same certificate, or installed apps will refuse
# the update, so back that folder up somewhere safe.
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-ContactMirror $NEW}"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.contactmirror-signing}"
KC="$SIGNING_DIR/signing.keychain-db"

[[ -f "$KC" ]] || { echo "Signing keychain not found at $KC"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password.txt")" "$KC"

swift test
VERSION="$NEW" SIGN_IDENTITY="ContactMirror Code Signing" SIGN_KEYCHAIN="$KC" ./scripts/build-app.sh

echo "$NEW" > VERSION
git add VERSION
git commit -m "Release $NEW"
git tag -a "v$NEW" -m "$NOTES"
git push origin HEAD "v$NEW"
gh release create "v$NEW" dist/ContactMirror.zip --title "ContactMirror $NEW" --notes "$NOTES"
echo "Published v$NEW"
