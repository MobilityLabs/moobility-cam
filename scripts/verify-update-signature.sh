#!/usr/bin/env bash
# Checks an update the way an installed copy will: the feed's signature on the zip, against the public key
# inside the app. A wrong key would otherwise publish an update that every installed copy refuses.
# Usage: verify-update-signature.sh <app> <zip> <appcast.xml>
set -euo pipefail
APP="$1"; ZIP="$2"; FEED="$3"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
[ -x "$OPENSSL" ] || OPENSSL=openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "UPDATE SIGNATURE FAILED: $*" >&2; exit 1; }

key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null) || fail "no SUPublicEDKey in the app"
signature=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$FEED" | head -1)
[ -n "$signature" ] || fail "no signature in $FEED"

# An Ed25519 public key in DER is a fixed 12-byte header, then the raw key.
python3 - "$key" "$signature" "$WORK" <<'PYTHON'
import base64, pathlib, sys
key, signature, work = sys.argv[1:4]
raw = base64.b64decode(key)
if len(raw) != 32:
    sys.exit("the public key isn't 32 bytes")
pathlib.Path(work, "public.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + raw)
pathlib.Path(work, "signature").write_bytes(base64.b64decode(signature))
PYTHON

"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/public.der" -keyform DER -rawin -in "$ZIP" -sigfile "$WORK/signature" >/dev/null 2>&1 \
  || fail "the feed's signature on $(basename "$ZIP") doesn't match the app's public key"
echo "UPDATE SIGNATURE OK"
