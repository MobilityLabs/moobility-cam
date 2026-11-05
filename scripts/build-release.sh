#!/usr/bin/env bash
# Builds, signs, notarizes and packages a release into dist/. The same script runs locally and in CI.
# Usage: build-release.sh <vX.Y.Z or X.Y.Z>
# Reads ASC_KEY_PATH, or the App Store Connect key in ~/.appstoreconnect/private_keys.
set -euo pipefail
cd "$(dirname "$0")/.."

ASC_KEY_ID="4XBH56T7RS"                                # names a key, authorizes nothing without it
ASC_ISSUER="22e2fb14-d32b-4837-92b0-6280da32716d"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
SIGN_ID="${MACOS_IDENTITY:-Developer ID Application: Sean Perkins (HH3SJBAS42)}"
[ -f "$KEY" ] || { echo "no App Store Connect key at $KEY" >&2; exit 1; }

VALUES=$(scripts/version-numbers.sh "${1:-}")
MARKETING_VERSION=$(sed -n 's/^MARKETING_VERSION=//p' <<<"$VALUES")
CURRENT_PROJECT_VERSION=$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' <<<"$VALUES")
TAG="v$MARKETING_VERSION"

WORK="build/release"
DIST="dist"
ARCHIVE="$WORK/MoobilityCam.xcarchive"
NOTARY=(--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")

notarize() {  # $1 = file to submit
  local result id
  result=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json)
  id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$result")
  if ! python3 -c 'import json,sys; sys.exit(json.loads(sys.argv[1])["status"] != "Accepted")' "$result"; then
    echo "notarization failed for $1:" >&2
    xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
    exit 1
  fi
  echo "notarized $(basename "$1")"
}

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$DIST"
xcodegen generate --quiet

# Manual signing with the profiles in scripts/profiles (see make-profiles.py). Xcode reads them by UUID from here.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
for profile in scripts/profiles/*.provisionprofile; do
  uuid=$(security cms -D -i "$profile" | plutil -extract UUID raw -)
  cp "$profile" "$PROFILE_DIR/$uuid.provisionprofile"
done
echo "--- archive $TAG ($CURRENT_PROJECT_VERSION)"
xcodebuild -project MoobilityCam.xcodeproj -scheme MoobilityCam -configuration Release \
  -derivedDataPath "$WORK/derived" -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  archive > "$WORK/archive.log" 2>&1 \
  || { grep -E "error:" "$WORK/archive.log" | head -20 >&2; echo "archive failed: $WORK/archive.log" >&2; exit 1; }

echo "--- export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$WORK/export" > "$WORK/export.log" 2>&1 \
  || { grep -E "error:" "$WORK/export.log" | head -20 >&2; echo "export failed: $WORK/export.log" >&2; exit 1; }
APP="$WORK/export/MoobilityCam.app"
scripts/verify-release.sh "$APP"

echo "--- notarize the app"
# notarytool doesn't take a bare .app.
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"
scripts/staple.sh "$APP"

echo "--- build the DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MoobilityCam.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname "Moobility Cam" -srcfolder "$STAGE" -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | tail -1 | sed -E 's/.*(\/Volumes\/.*)/\1/')
xcrun SetFile -a C "$MOUNT" 2>/dev/null || echo "no volume icon: SetFile unavailable"
hdiutil detach -quiet "$MOUNT"
DMG="$DIST/Moobility-Cam-$TAG.dmg"
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
notarize "$DMG"
scripts/staple.sh "$DMG"
cp "$DMG" "$DIST/Moobility-Cam.dmg"

spctl --assess --type execute -v "$APP"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "--- zip for updates"
# ditto keeps a bundle's symlinks intact; zip doesn't, and a mangled bundle fails its signature after updating.
mkdir -p "$DIST/update"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/update/Moobility-Cam-$TAG.zip"

echo "--- done"
ls -la "$DIST" "$DIST/update"
