#!/usr/bin/env bash
# Generate, build and sign Moobility Cam, then verify entitlements and bundled resources.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "BUILD CHECK FAILED: $*" >&2; exit 1; }

check_extension_plist() {  # $1 = .systemextension bundle
  local plist="$1/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null)" = "SYSX" ] \
    || fail "extension CFBundlePackageType is not SYSX"
  /usr/libexec/PlistBuddy -c 'Print :NSSystemExtensionUsageDescription' "$plist" >/dev/null 2>&1 \
    || fail "extension NSSystemExtensionUsageDescription missing"
  local mach group
  mach=$(/usr/libexec/PlistBuddy -c 'Print :CMIOExtension:CMIOExtensionMachServiceName' "$plist" 2>/dev/null)
  group=$(codesign -d --entitlements - --xml "$1" 2>/dev/null \
    | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read())["com.apple.security.application-groups"][0])' 2>/dev/null) || true
  [ -n "$group" ] && [[ "$mach" == "$group".* ]] \
    || fail "Mach service '$mach' is not prefixed by app group '$group.'"
}
[ "${CHECK_PLIST_ONLY:-}" ] && { check_extension_plist "$CHECK_PLIST_ONLY"; echo "PLIST CHECK OK"; exit 0; }

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project MoobilityCam.xcodeproj -scheme MoobilityCam -configuration Debug \
    -derivedDataPath build -allowProvisioningUpdates build > build/xcodebuild.log 2>&1; then
  grep -E "error:|warning: .*provision" build/xcodebuild.log | head -20 >&2
  fail "xcodebuild failed (full log: build/xcodebuild.log)"
fi

APP=build/Build/Products/Debug/MoobilityCam.app
EXT="$APP/Contents/Library/SystemExtensions/com.mobilitylabs.MoobilityCam.Extension.systemextension"
[ -d "$APP" ] || fail "missing $APP"
[ -d "$EXT" ] || fail "extension not embedded at $EXT"

app_ents=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
for k in system-extension.install application-groups device.camera; do
  grep -q "$k" <<<"$app_ents" || fail "app entitlement missing: $k"
done
ext_ents=$(codesign -d --entitlements - --xml "$EXT" 2>/dev/null)
for k in app-sandbox application-groups; do
  grep -q "$k" <<<"$ext_ents" || fail "extension entitlement missing: $k"
done

for f in "$APP"/Contents/Resources/{spring,summer,autumn,winter}.jpg "$EXT/Contents/Resources/idle.png"; do
  [ -f "$f" ] || fail "missing resource: $f"
done

check_extension_plist "$EXT"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
[[ "$(plist_value "$APP" CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "app build number isn't a number"
[[ "$(plist_value "$EXT" CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "extension build number isn't a number"

echo "BUILD CHECK OK"
