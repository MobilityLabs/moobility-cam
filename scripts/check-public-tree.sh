#!/usr/bin/env bash
# Keeps the public repo clean: fails if a file that belongs only in the private archive is tracked,
# or if another tracked file holds a personal path.
set -euo pipefail
LEFT_OUT='^(final/|docs/|contact-sheet\.png$|composite\.py$|pick_background\.py$|holiday-backgrounds\.md$|schedule\.json$|scripts/moobility-library\.json$|scripts/seed-moobility-library\.py$|scripts/compose-seasons\.py$|scripts/export-public-tree\.sh$|scripts/test-export-public-tree\.sh$|MoobilityCore/Tests/MoobilityCoreTests/SeedTests\.swift$)'

status=0
found=$(git ls-files | grep -E "$LEFT_OUT" || true)
extra_raw=$(git ls-files | grep -E '^raw/' | grep -vE '^raw/(seasons|cows)/' || true)
if [[ -n "$found$extra_raw" ]]; then
  echo "these belong only in the private archive:"
  printf '%s\n%s\n' "$found" "$extra_raw" | sed '/^$/d'
  status=1
fi

personal=$(git grep -nIE '/Users/[a-z0-9._-]+/' -- . ':!scripts/check-public-tree.sh' | grep -v '/Users/someone/' || true)
if [[ -n "$personal" ]]; then
  echo "personal paths:"
  echo "$personal"
  status=1
fi
[[ $status == 0 ]] && echo "PUBLIC TREE OK"
exit $status
