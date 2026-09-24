#!/usr/bin/env bash
# Builds a signed, notarized Flowtype DMG and the Sparkle appcast.
#
# One-time setup (stores notarization credentials in your keychain):
#   xcrun notarytool store-credentials flowtype-notary \
#     --apple-id <you@example.com> --team-id HZHNBYQCWN --password <app-specific-password>
#
# Usage:
#   scripts/release.sh            # build, notarize, create DMG + appcast in build/release
#   scripts/release.sh --publish  # also create the GitHub release (public!)
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-flowtype-notary}"
SPARKLE_ACCOUNT="studio.infinitumlabs.flowtype"
REPO="yashgo0018/flowtype"
PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

OUT="build/release"
DERIVED="build/DerivedData"
ARCHIVE="$OUT/Flowtype.xcarchive"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first; releases are built from a clean tree."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "No notarization credentials named '$NOTARY_PROFILE'. See the setup comment at the top of this script."

VERSION=$(xcodebuild -project Flowtype.xcodeproj -scheme Flowtype -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = / && !found { print $2; found = 1 }')
# Sparkle compares CFBundleVersion, so it must increase with every release.
BUILD=$(git rev-list --count HEAD)
TAG="v$VERSION"
DMG="$OUT/Flowtype-$VERSION.dmg"
[[ -n "$VERSION" ]] || fail "Could not read MARKETING_VERSION."
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "Tag $TAG already exists. Bump MARKETING_VERSION in the project first."
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving Flowtype $VERSION ($BUILD)"
xcodebuild archive \
  -project Flowtype.xcodeproj -scheme Flowtype -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet

step "Exporting with Developer ID signing"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -allowProvisioningUpdates -quiet
APP="$OUT/export/Flowtype.app"
codesign --verify --deep --strict "$APP"

notary() {
  xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE" --output-format json
}

# Submits a file and waits for Apple's verdict. The wait can take an hour for a new team, so a
# dropped connection while polling is retried instead of aborting the release.
notarize() {
  local file="$1" id="" status="In Progress" deadline=$((SECONDS + 4 * 3600))
  for attempt in 1 2 3; do
    id=$(notary submit "$file" 2>/dev/null | plutil -extract id raw -o - - 2>/dev/null) && [[ -n "$id" ]] && break
    echo "Upload attempt $attempt failed; retrying in 30s..."
    sleep 30
  done
  [[ -n "$id" ]] || fail "Could not upload $file for notarization."
  echo "Submitted $(basename "$file") (submission $id). Waiting for Apple..."

  while [[ "$status" == "In Progress" ]]; do
    (( SECONDS < deadline )) || fail "Still in progress after 4 hours. Check later: xcrun notarytool info $id --keychain-profile $NOTARY_PROFILE"
    sleep 30
    # A failed check (e.g. offline) leaves the status unchanged, so we keep polling.
    status=$(notary info "$id" 2>/dev/null | plutil -extract status raw -o - - 2>/dev/null || echo "In Progress")
  done

  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    fail "Notarization of $(basename "$file") finished with status: $status"
  fi
  echo "Accepted."
}

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Flowtype.zip"
notarize "$OUT/Flowtype.zip"
xcrun stapler staple "$APP"
rm "$OUT/Flowtype.zip"

step "Building the DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Flowtype" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGING"
# awk reads all input (no early exit): closing the pipe early would SIGPIPE codesign and fail under pipefail.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/^Authority=Developer ID Application/ && !found { print $2; found = 1 }')
[[ -n "$IDENTITY" ]] || fail "The exported app isn't signed with a Developer ID Application certificate."
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"

step "Generating the Sparkle appcast"
UPDATES="$OUT/updates"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
# Keep earlier releases in the feed.
curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$UPDATES/appcast.xml" 2>/dev/null || rm -f "$UPDATES/appcast.xml"
"$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  "$UPDATES"
cp "$UPDATES/appcast.xml" "$OUT/appcast.xml"

step "Done"
echo "DMG:     $DMG"
echo "Appcast: $OUT/appcast.xml"

if $PUBLISH; then
  step "Publishing $TAG to GitHub"
  git tag "$TAG"
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "Flowtype $VERSION" --generate-notes
else
  echo
  echo "To publish: scripts/release.sh --publish (or upload both files to a GitHub release tagged $TAG)."
fi
