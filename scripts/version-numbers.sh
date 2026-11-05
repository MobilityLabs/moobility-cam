#!/usr/bin/env bash
# Turns a tag or version into the two values xcodebuild takes. Build number: X*1000000 + Y*1000 + Z.
set -euo pipefail
input="${1:-}"
version="${input#v}"
# The pattern bounds each part before any arithmetic, so a huge value can't wrap around, and
# it refuses leading zeros, so v1.02.3 and v1.2.3 can't share a build number.
if [[ ! "$version" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
  echo "not a version: '$input' (expected vX.Y.Z or X.Y.Z, minor and patch under 1000)" >&2
  exit 1
fi
major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
echo "MARKETING_VERSION=$version"
echo "CURRENT_PROJECT_VERSION=$((major * 1000000 + minor * 1000 + patch))"
