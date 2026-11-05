#!/bin/zsh
# One-time setup of signing for .github/workflows/release.yml. Run it yourself: it uses your keychain export and your
# GitHub login, and it writes to GitHub.
#
#   1. Keychain Access -> login keychain -> "My Certificates" -> select
#      "Developer ID Application: Sean Perkins (HH3SJBAS42)" (the one with a private key, not another team's item)
#      -> File > Export Items... -> Personal Information Exchange (.p12), with any new password.
#   2. scripts/configure-release-ci.sh /path/to/exported.p12
#
# The signing p12 is re-wrapped under a freshly generated passphrase, checked to be a Developer ID identity WITH its
# private key, and only then pushed to a PRIVATE vault repo. The runner reads the vault with a read-only deploy key made
# new on every run. Notarisation uses the App Store Connect API key (checked-in id and issuer; only the .p8 is secret).
#
# Sparkle's update key is exported from the login keychain, where `generate_keys --account moobility-cam` made it.
#
# Variables: REPO (default MobilityLabs/moobility-cam), VAULT (default MobilityLabs/moobility-cam-macos-certs) and ASC_KEY_ID
# (default 4XBH56T7RS), which must match what release.yml uses (the script refuses anything else), MACOS_IDENTITY (default
# the Developer ID above; the p12 must contain it), ASC_KEY_FILE (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
# and OPENSSL (an OpenSSL 3.x binary).
set -euo pipefail

REPO="${REPO:-MobilityLabs/moobility-cam}"
VAULT="${VAULT:-MobilityLabs/moobility-cam-macos-certs}"
ASC_KEY_ID="${ASC_KEY_ID:-4XBH56T7RS}"
IDENTITY="${MACOS_IDENTITY:-Developer ID Application: Sean Perkins (HH3SJBAS42)}"
KEY_TITLE="moobility-cam GitHub Actions (read-only)"

# First, before anything else is looked at: never write to another project's vault or secrets.
for target in "$REPO" "$VAULT"; do
  case "$target" in
    *rootkit*|*loftline*|*sound-mural*)
      print -u2 -r -- "refusing to use $target: it belongs to another project, and this script would replace its signing material"
      exit 1 ;;
  esac
  [[ $target =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || { print -u2 -r -- "not an owner/name repo: $target"; exit 1; }
done

# The workflow is what consumes these values (it clones the vault and notarises with the key id), so a setup that
# provisioned anything else would report success and leave CI unable to authenticate. The values are read from it.
workflow="${0:A:h}/../.github/workflows/release.yml"
[[ -f $workflow ]] || { print -u2 -r -- "cannot find $workflow"; exit 1; }
workflow_vault="$(sed -n 's/.*git@github\.com:\([A-Za-z0-9._\/-]*\)\.git.*/\1/p' "$workflow" | head -1)"
workflow_key_id="$(sed -n 's/^ASC_KEY_ID="\([A-Z0-9]*\)".*/\1/p' "${0:A:h}/build-release.sh" | head -1)"
if [[ $VAULT != "$workflow_vault" ]]; then
  print -u2 -r -- "refusing VAULT=$VAULT: release.yml clones ${workflow_vault:-<nothing>}; change both together, in a commit"
  exit 1
fi
if [[ $ASC_KEY_ID != "$workflow_key_id" ]]; then
  print -u2 -r -- "refusing ASC_KEY_ID=$ASC_KEY_ID: build-release.sh notarises with ${workflow_key_id:-<nothing>}; change both together, in a commit"
  exit 1
fi

P12="${1:?usage: scripts/configure-release-ci.sh <exported-signing.p12>}"
P8="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

# The one argument is the exported .p12 (binary). A text PEM there is nearly always the App Store Connect key, which the
# script finds itself; OpenSSL's answer to it ("wrong tag ... Type=PKCS12") does not say so. Checked before OpenSSL is run.
if [[ -f $P12 ]] && head -c 4096 -- "$P12" | LC_ALL=C grep -aq -e '-----BEGIN'; then
  print -u2 -r -- "$P12 is a PEM text file, not an exported .p12"
  print -u2 -r -- "the argument is the Personal Information Exchange (.p12) file from Keychain Access; the script finds the App Store Connect key itself ($P8)"
  exit 1
fi

# OpenSSL 3.x is required: -legacy and -macalg sha1 control the RC2-40 encoding macOS `security import` accepts, and
# /usr/bin/openssl on macOS is LibreSSL, which has neither flag.
OPENSSL="${OPENSSL:-openssl}"
if ! "$OPENSSL" version 2>/dev/null | grep -q "OpenSSL 3"; then
  print -u2 -r -- "need OpenSSL 3.x, got: $("$OPENSSL" version 2>&1 || true)"
  print -u2 -r -- "try: brew install openssl@3 && OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl $0 $P12"
  exit 1
fi
[[ -f $P12 ]] || { print -u2 -r -- "no such file: $P12"; exit 1; }
[[ -f $P8 ]] || { print -u2 -r -- "no App Store Connect key at $P8 (expected key id $ASC_KEY_ID)"; exit 1; }
read -rs "P12PW?original p12 password (the one you set in Keychain Access): "
print
[[ -n $P12PW ]] || { print -u2 -r -- "empty password"; exit 1; }

umask 077
# Temp files get neutral names, not *.pem or *.p12: tools that refuse credential-looking paths (the agent sandbox the
# script's tests run in does) can then run it. The file in the vault keeps the name release.yml reads.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- re-wrap under a generated passphrase ------------------------------------
# Passphrases travel in the environment (-passin env:...), not in argv, where any process could read them.
VLT_PW="$("$OPENSSL" rand -hex 24)"
export P12PW VLT_PW
# Keychain Access exports a legacy RC2/3DES p12 that OpenSSL 3.x refuses without -legacy: try modern, then legacy on the
# input side only. Every stage uses files: OpenSSL 3.6's `pkcs12 -export` cannot read a PEM stream from stdin.
if ! "$OPENSSL" pkcs12 -in "$P12" -passin env:P12PW -nodes -out "$TMP/identity-dump.txt" 2>"$TMP/rw.err"; then
  "$OPENSSL" pkcs12 -legacy -in "$P12" -passin env:P12PW -nodes -out "$TMP/identity-dump.txt" 2>"$TMP/rw.err" \
    || { print -u2 -r -- "could not read the p12; openssl said:"; cat "$TMP/rw.err" >&2; exit 1; }
  print "read the p12 with -legacy (Keychain Access legacy encoding)"
fi
# macOS `security import` accepts only -legacy -macalg sha1 on a real PKCS#12; OpenSSL 3 defaults and bare -legacy both
# fail with "MAC verification failed".
"$OPENSSL" pkcs12 -legacy -macalg sha1 -export -in "$TMP/identity-dump.txt" -passout env:VLT_PW -out "$TMP/signing-pkcs12.bin" 2>"$TMP/rw2.err" \
  || { print -u2 -r -- "could not re-export the p12; openssl said:"; cat "$TMP/rw2.err" >&2; exit 1; }

# --- verify WHAT was exported before anything is pushed ----------------------
# Catches another team's item or a certificate exported without its key here, not as a burnt CI run.
"$OPENSSL" pkcs12 -legacy -in "$TMP/signing-pkcs12.bin" -passin env:VLT_PW -nodes -out "$TMP/verify-dump.txt" 2>"$TMP/verify.err" \
  || { print -u2 -r -- "could not verify the re-wrapped p12; openssl said:"; cat "$TMP/verify.err" >&2; exit 1; }
SUBJECTS="$("$OPENSSL" crl2pkcs7 -nocrl -certfile "$TMP/verify-dump.txt" | "$OPENSSL" pkcs7 -print_certs -noout)"
# The login keychain can hold more than one team's Developer ID item. The one in the vault must be the identity the
# workflow will ask codesign for, or CI fails at the signing step with the vault and the secrets already replaced.
[[ $SUBJECTS == *"$IDENTITY"* ]] \
  || { print -u2 -r -- "WRONG IDENTITY: the p12 holds $SUBJECTS"; print -u2 -r -- "expected the certificate '$IDENTITY'; nothing was pushed"; exit 1; }
grep -qE "BEGIN (RSA )?PRIVATE KEY" "$TMP/verify-dump.txt" \
  || { print -u2 -r -- "no private key in the p12: was the certificate exported without its key?"; exit 1; }
print "verified: Developer ID Application identity with its private key"

# --- the vault: private, created if missing ----------------------------------
if gh repo view "$VAULT" >/dev/null 2>&1; then
  visibility="$(gh repo view "$VAULT" --json visibility --jq .visibility)"
  [[ $visibility == PRIVATE ]] || { print -u2 -r -- "$VAULT is $visibility; the signing vault must be private"; exit 1; }
else
  gh repo create "$VAULT" --private --description "Encrypted signing identity for $REPO releases"
fi
gh repo clone "$VAULT" "$TMP/vault" -- --depth=1
cp "$TMP/signing-pkcs12.bin" "$TMP/vault/macos-signing.p12"
( cd "$TMP/vault" \
  && git checkout -q -B main \
  && git add macos-signing.p12 \
  && git commit -q -m "macos-signing.p12: $(date -u +%Y-%m-%d)" \
  && git push -q origin HEAD:main )
print "pushed the re-wrapped p12 to $VAULT"

# --- a NEW read-only deploy key, CI's way into the vault ---------------------
# Always a new pair: reusing whatever key is already on the vault would leave the secret holding a private key that does
# not match it. The previous keys with this title are retired once the secret below is in place.
ssh-keygen -q -t ed25519 -f "$TMP/macos_certs_ed25519" -N "" -C "moobility-cam-release-ci"
old_keys=(${(f)"$(gh repo deploy-key list -R "$VAULT" --json id,title --jq ".[] | select(.title == \"$KEY_TITLE\") | .id")"})
gh repo deploy-key add "$TMP/macos_certs_ed25519.pub" -R "$VAULT" -t "$KEY_TITLE"
print "added a read-only deploy key to $VAULT"

# --- the environment: only main and v* tags can reach the secrets -------------
# A guard inside the workflow isn't enough: anyone able to push a branch could edit it and run that branch by hand.
print -r -- '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  | gh api -X PUT "repos/$REPO/environments/release" --input - >/dev/null
for pattern in main:branch 'v*':tag; do
  print -r -- "{\"name\":\"${pattern%%:*}\",\"type\":\"${pattern##*:}\"}" \
    | gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" --input - >/dev/null 2>&1 || true
done
print "the release environment takes main and v* tags only"

# --- the secrets: only in that environment, and never on a command line -------
gh secret set MACOS_CERTS_DEPLOY_KEY --repo "$REPO" --env release < "$TMP/macos_certs_ed25519"
print -rn -- "$VLT_PW" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO" --env release
base64 < "$P8" | gh secret set ASC_KEY_CONTENT --repo "$REPO" --env release
print -rn -- "$IDENTITY" | gh secret set MACOS_IDENTITY --repo "$REPO" --env release

# --- Sparkle's update key, from the login keychain ---------------------------
GENERATE_KEYS="$(find "${0:A:h}/../build" -type f -name generate_keys 2>/dev/null | head -1)"
[[ -n $GENERATE_KEYS ]] || { print -u2 -r -- "Sparkle's generate_keys is missing: run scripts/check-build.sh once first"; exit 1; }
"$GENERATE_KEYS" --account moobility-cam -x "$TMP/update-key.txt"
[[ -s $TMP/update-key.txt ]] || { print -u2 -r -- "could not export the update key from the keychain"; exit 1; }
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" --env release < "$TMP/update-key.txt"

for id in $old_keys; do
  gh repo deploy-key delete "$id" -R "$VAULT" && print "retired the previous deploy key $id"
done

print "secrets set in $REPO:"
print "  MACOS_CERTS_DEPLOY_KEY  (read-only key into $VAULT)"
print "  MACOS_CERT_PASSWORD     (the generated vault passphrase)"
print "  ASC_KEY_CONTENT         (base64 of AuthKey_${ASC_KEY_ID}.p8)"
print "  MACOS_IDENTITY"
print "  SPARKLE_PRIVATE_KEY     (Sparkle's update signing key)"
print "check with: gh secret list -R $REPO --env release"
