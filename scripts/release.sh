#!/usr/bin/env bash
# Builds a signed, notarized Flowtype DMG and the Sparkle appcast.
#
# One-time setup (stores notarization credentials in your keychain):
#   xcrun notarytool store-credentials flowtype-notary --apple-id <you@example.com> --team-id HZHNBYQCWN
# (It prompts for an app-specific password. See RELEASING.md.)
#
# Usage:
#   scripts/release.sh            # build, notarize, create DMG + appcast in build/release
#   scripts/release.sh --resume   # continue an interrupted build without starting over
#   scripts/release.sh --publish  # upload exactly those files as a GitHub release (public!)
#
# Publishing never rebuilds: what you tested is what ships.
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-flowtype-notary}"
SPARKLE_ACCOUNT="studio.infinitumlabs.flowtype"
REPO="yashgo0018/flowtype"
MODE="${1:-build}"

OUT="build/release"
DERIVED="build/DerivedData"
ARCHIVE="$OUT/Flowtype.xcarchive"
APP="$OUT/export/Flowtype.app"
STATE="$OUT/BUILD_INFO"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first; releases are built from a clean tree."

load_state() {
  [[ -f "$STATE" ]] || fail "Nothing built yet. Run scripts/release.sh first."
  # shellcheck source=/dev/null
  source "$STATE"
  [[ "$BUILT_COMMIT" == "$(git rev-parse HEAD)" ]] \
    || fail "The code changed since the last build ($BUILT_COMMIT). Run scripts/release.sh to build again."
  VERSION="$BUILT_VERSION"
  BUILD="$BUILT_BUILD"
  DMG="$OUT/Flowtype-$VERSION.dmg"
  TAG="v$VERSION"
}

# MARK: - Publish

publish() {
  [[ "$(git branch --show-current)" == "main" ]] || fail "Publish from main (the app links to files on main)."
  load_state
  [[ "${BUILT_COMPLETE:-0}" == 1 ]] || fail "The last build didn't finish. Run scripts/release.sh --resume."
  xcrun stapler validate "$DMG" >/dev/null || fail "$DMG is not notarized."
  if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "Tag $TAG already exists. Bump MARKETING_VERSION for a new release."
  fi

  step "Publishing Flowtype $VERSION ($BUILD) to GitHub"
  git tag "$TAG"
  git push origin HEAD "$TAG"
  # Also attach the DMG as Flowtype.dmg so releases/latest/download/Flowtype.dmg always works.
  cp "$DMG" "$OUT/Flowtype.dmg"
  gh release create "$TAG" "$DMG" "$OUT/Flowtype.dmg" "$OUT/appcast.xml" --repo "$REPO" --title "Flowtype $VERSION" --generate-notes
}

case "$MODE" in
  --publish) publish; exit 0 ;;
  --resume|build) ;;
  *) fail "Unknown option '$MODE'. Use no option, --resume or --publish." ;;
esac

# MARK: - Notarization

notary() {
  xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE" --output-format json
}

# Submits a file (or, when resuming, reuses its earlier submission) and waits for Apple's verdict.
# New teams can wait hours, so network drops and a locked Mac (the keychain holding the notary
# credentials is unavailable while locked) are waited out instead of aborting the release.
notarize() {
  local file="$1" id_file
  id_file="$OUT/$(basename "$1").submission"
  local id="" status="In Progress" reason="" last_reason="" output
  local deadline=$((SECONDS + 12 * 3600))

  if [[ -s "$id_file" ]]; then
    id=$(<"$id_file")
    echo "Resuming submission $id for $(basename "$file")."
  else
    for attempt in 1 2 3; do
      id=$(notary submit "$file" 2>/dev/null | plutil -extract id raw -o - - 2>/dev/null) && [[ -n "$id" ]] && break
      echo "Upload attempt $attempt failed; retrying in 30s..."
      sleep 30
    done
    [[ -n "$id" ]] || fail "Could not upload $file for notarization."
    echo "$id" > "$id_file"
    echo "Submitted $(basename "$file") (submission $id). Waiting for Apple..."
  fi

  while [[ "$status" == "In Progress" ]]; do
    (( SECONDS < deadline )) || fail "Still waiting after 12 hours. Resume later with: scripts/release.sh --resume"
    if output=$(notary info "$id" 2>&1) && status=$(plutil -extract status raw -o - - <<<"$output" 2>/dev/null); then
      reason=""
    else
      status="In Progress"
      if grep -qi "keychain" <<<"$output"; then
        reason="Can't read the notary credentials from the keychain. Is the Mac locked? Waiting..."
      else
        reason="Can't reach Apple's notary service. Waiting..."
      fi
    fi
    if [[ -n "$reason" && "$reason" != "$last_reason" ]]; then
      echo "$reason"
    fi
    last_reason="$reason"
    if [[ "$status" == "In Progress" ]]; then
      sleep 30
    fi
  done

  if [[ "$status" != "Accepted" ]]; then
    rm -f "$id_file"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    fail "Notarization of $(basename "$file") finished with status: $status"
  fi
  echo "Accepted."
}

# MARK: - Build

if [[ "$MODE" == "--resume" ]]; then
  load_state
  [[ -d "$APP" ]] || fail "No exported app to resume from. Run scripts/release.sh to build again."
  step "Resuming Flowtype $VERSION ($BUILD)"
else
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "Can't use the notarization credentials '$NOTARY_PROFILE'. Unlock the Mac, or see the setup comment at the top of this script."

  VERSION=$(xcodebuild -project Flowtype.xcodeproj -scheme Flowtype -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION = / && !found { print $2; found = 1 }')
  [[ -n "$VERSION" ]] || fail "Could not read MARKETING_VERSION."
  # Sparkle compares CFBundleVersion, so it must increase with every release.
  BUILD=$(git rev-list --count HEAD)
  TAG="v$VERSION"
  DMG="$OUT/Flowtype-$VERSION.dmg"
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
  codesign --verify --deep --strict "$APP"

  cat > "$STATE" <<INFO
BUILT_COMMIT=$(git rev-parse HEAD)
BUILT_VERSION=$VERSION
BUILT_BUILD=$BUILD
BUILT_COMPLETE=0
INFO
fi

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  step "Notarizing the app"
  [[ -f "$OUT/Flowtype.zip" ]] || ditto -c -k --keepParent "$APP" "$OUT/Flowtype.zip"
  notarize "$OUT/Flowtype.zip"
  xcrun stapler staple "$APP"
  rm -f "$OUT/Flowtype.zip"
fi

# A DMG that was already submitted must not be rebuilt, or it would no longer match its ticket.
if [[ ! -f "$DMG.submission" ]]; then
  step "Building the DMG"
  STAGING="$OUT/dmg"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Flowtype" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet
  rm -rf "$STAGING"
  # awk reads all input (no early exit): closing the pipe early would SIGPIPE codesign and fail under pipefail.
  IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/^Authority=Developer ID Application/ && !found { print $2; found = 1 }')
  [[ -n "$IDENTITY" ]] || fail "The exported app isn't signed with a Developer ID Application certificate."
  # Xcode's cloud-managed Developer ID certificate signs the export but has no local private key.
  # Signing the DMG itself is optional: a notarized, stapled DMG passes Gatekeeper either way.
  if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
  else
    echo "No local '$IDENTITY' key; leaving the DMG unsigned (it is still notarized and stapled)."
  fi
fi

if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  step "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
xcrun stapler validate "$DMG"
spctl --assess --type execute "$APP"

step "Generating the Sparkle appcast"
UPDATES="$OUT/updates"
rm -rf "$UPDATES"
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

sed -i '' 's/^BUILT_COMPLETE=0$/BUILT_COMPLETE=1/' "$STATE"

step "Done"
echo "DMG:     $DMG"
echo "Appcast: $OUT/appcast.xml"
echo
echo "Test the DMG, then publish exactly these files with: scripts/release.sh --publish"
