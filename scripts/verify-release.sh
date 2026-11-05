#!/usr/bin/env bash
# Checks an exported app before it's notarized or shipped. Prints the failed check and exits non-zero.
# Usage: verify-release.sh <path to MoobilityCam.app>
set -uo pipefail
APP="${1:-}"
TEAM="HH3SJBAS42"
fail() { echo "VERIFY FAILED: $*"; exit 1; }

[ -d "$APP/Contents" ] || fail "no app bundle at '$APP'"
EXT="$APP/Contents/Library/SystemExtensions/com.mobilitylabs.MoobilityCam.Extension.systemextension"
[ -d "$EXT" ] || fail "extension not embedded"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

for bundle in "$APP" "$EXT"; do
  name=$(basename "$bundle")
  executable=$(plist "$bundle" CFBundleExecutable)
  binary="$bundle/Contents/MacOS/$executable"
  [ -f "$binary" ] || fail "$name: no executable"
  archs=$(lipo -archs "$binary" 2>/dev/null)
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$name: architectures are '$archs', need arm64 and x86_64"
  info=$(codesign -dvvv "$bundle" 2>&1)
  grep -q "Authority=Developer ID Application" <<<"$info" || fail "$name: not signed with Developer ID"
  grep -q "TeamIdentifier=$TEAM" <<<"$info" || fail "$name: wrong team"
  grep -q "flags=.*runtime" <<<"$info" || fail "$name: no hardened runtime"
  codesign --verify --strict --deep "$bundle" 2>/dev/null || fail "$name: signature doesn't verify"
  entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null)
  grep -q "get-task-allow" <<<"$entitlements" && fail "$name: has get-task-allow"
  grep -q "application-groups" <<<"$entitlements" || fail "$name: no app group entitlement"
done
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
for key in system-extension.install device.camera; do
  grep -q "$key" <<<"$entitlements" || fail "app: missing entitlement $key"
done
codesign -d --entitlements - --xml "$EXT" 2>/dev/null | grep -q "app-sandbox" || fail "extension: not sandboxed"

[[ "$(plist "$APP" CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "app build number isn't a number"
[[ "$(plist "$EXT" CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "extension build number isn't a number"

key=$(plist "$APP" SUPublicEDKey)
[[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "SUPublicEDKey isn't a real key: '$key'"
[ -n "$(plist "$APP" SUFeedURL)" ] || fail "no update feed"

for season in spring summer autumn winter; do
  [ -f "$APP/Contents/Resources/$season.jpg" ] || fail "missing season image: $season"
done
[ -f "$EXT/Contents/Resources/idle.png" ] || fail "missing idle image"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "missing app icon"
# Everything the app bundles by name is checked above, so a loose image here is something that slipped in.
stray=$(find "$APP/Contents/Resources" -maxdepth 1 -type f \( -name '*.png' -o -name '*.json' \) -print -quit)
[ -z "$stray" ] || fail "unexpected file in the app: $stray"
echo "VERIFY OK: $(plist "$APP" CFBundleShortVersionString) ($(plist "$APP" CFBundleVersion)), extension build $(plist "$EXT" CFBundleVersion)"
