#!/usr/bin/env bash
# Staples a notarized app or DMG and validates the result, retrying because Apple's ticket service can drop a connection.
# Usage: staple.sh <path>. STAPLE_WAIT sets the base wait in seconds between tries.
set -uo pipefail
TARGET="${1:?usage: staple.sh <path>}"
WAIT="${STAPLE_WAIT:-30}"
ATTEMPTS=5

for attempt in $(seq 1 "$ATTEMPTS"); do
  xcrun stapler staple "$TARGET" && xcrun stapler validate "$TARGET" && exit 0
  echo "stapling $TARGET failed on try $attempt of $ATTEMPTS" >&2
  [ "$attempt" -lt "$ATTEMPTS" ] && sleep $((WAIT * attempt))
done
exit 1
