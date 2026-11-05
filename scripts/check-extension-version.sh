#!/usr/bin/env bash
# Fails if Extension/ changed since the last tag and EXTENSION_BUILD didn't. macOS only replaces the
# extension when its version changes, so a missed bump would ship code that never runs.
# EXTENSION_BUILD is raised only when needed, because replacing a running extension can need a restart.
# Usage: check-extension-version.sh <last tag, or empty for the first release>
set -euo pipefail
last="${1:-}"
[[ -n "$last" ]] || { echo "no previous release"; exit 0; }
git diff --quiet "$last" HEAD -- Extension && { echo "Extension/ unchanged since $last"; exit 0; }
value() { grep -E '^ *EXTENSION_BUILD:' | grep -oE '"[0-9]+"' | tr -d '"'; }
before=$(git show "$last:project.yml" | value || true)
now=$(git show HEAD:project.yml | value)
if [[ "$before" == "$now" ]]; then
  echo "Extension/ changed since $last, but EXTENSION_BUILD is still $now. Raise it in project.yml." >&2
  exit 1
fi
echo "Extension/ changed, EXTENSION_BUILD $before -> $now"
