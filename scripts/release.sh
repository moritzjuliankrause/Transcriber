#!/bin/zsh
# Publishes a new version: bumps CFBundleShortVersionString, commits, tags vX.Y.Z,
# builds AnyRecord.app, zips it and creates a GitHub release with the zip attached.
#   ./scripts/release.sh 0.2.0 ["release notes"]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Release $VERSION}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree not clean – commit first." >&2; exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
git add Resources/Info.plist
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "AnyRecord $VERSION"

./scripts/bundle.sh release
ZIP="dist/AnyRecord-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/AnyRecord.app "$ZIP"

git push -q origin main --tags
gh release create "v$VERSION" "$ZIP" --title "AnyRecord $VERSION" --notes "$NOTES"
echo "Released v$VERSION → $(gh release view "v$VERSION" --json url -q .url)"
