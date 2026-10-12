#!/bin/zsh
# Publishes a new version: bumps CFBundleShortVersionString, commits, tags vX.Y.Z,
# builds Transcriber.app, zips it and creates a GitHub release with the zip attached.
#   ./scripts/release.sh 0.2.0 ["release notes"]
# A version with a suffix (0.3.0-beta.1, 1.0.0-rc.2) becomes a GitHub *pre-release*:
# the app's normal update check ignores it; only users who enabled
# "Include pre-releases" in Settings are offered it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Release $VERSION}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree not clean – commit first." >&2; exit 1
fi

# Users only accept an update signed by the same certificate as their installed copy.
PINNED=$(grep -v '^#' scripts/signing-certificate.sha1 | tr -d '[:space:]')
if ! security find-identity -p codesigning | grep -q "$PINNED"; then
  echo "Release certificate $PINNED is not in the keychain – existing users could not install" >&2
  echo "this update. Import it (see scripts/signing-certificate.sha1) before releasing." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
# Add the release notes to CHANGELOG.md (shown in the app under Settings → Show Changes),
# unless a section for this version was written by hand already.
if ! grep -q "^## $VERSION " CHANGELOG.md; then
  ENTRY="## $VERSION ($(date +%Y-%m-%d))"$'\n'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in -*) ENTRY+="$line"$'\n' ;; *) ENTRY+="- $line"$'\n' ;; esac
  done <<< "$NOTES"
  N=$(grep -n '^## ' CHANGELOG.md | head -1 | cut -d: -f1)
  { head -n $((N - 1)) CHANGELOG.md; printf '%s\n' "$ENTRY"; tail -n +"$N" CHANGELOG.md; } > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
fi
git add Resources/Info.plist CHANGELOG.md
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "Transcriber $VERSION"

./scripts/bundle.sh release
SIGNED=$(codesign -dr - dist/Transcriber.app 2>&1 | sed -nE 's/.*certificate leaf = H"([0-9a-fA-F]+)".*/\1/p' | tr a-f A-F)
if [ "$SIGNED" != "$PINNED" ]; then
  echo "dist/Transcriber.app is signed with ${SIGNED:-no certificate}, not $PINNED – not publishing." >&2
  echo "Undo the local release commit and tag: git tag -d v$VERSION && git reset --hard HEAD~1" >&2
  exit 1
fi
ZIP="dist/Transcriber-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/Transcriber.app "$ZIP"

git push -q origin main --tags
PRERELEASE=()
[[ "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)
gh release create "v$VERSION" "$ZIP" --title "Transcriber $VERSION" --notes "$NOTES" "${PRERELEASE[@]}"
echo "Released v$VERSION → $(gh release view "v$VERSION" --json url -q .url)"
