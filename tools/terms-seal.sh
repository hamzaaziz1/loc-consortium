#!/usr/bin/env bash
#
# Seals letter of credit terms for the parties entitled to read them, and
# prints the commitment to put on chain.
#
# Envelope encryption via CMS (RFC 5652): the terms are encrypted once under a
# random content key, and that key is wrapped separately for each recipient's
# encryption certificate using ECDH.
#
# WHY ENVELOPE RATHER THAN ENCRYPTING TO EACH PARTY SEPARATELY. Certificates
# rotate annually (ADR 0004) and a credit outlives a rotation. Encrypting the
# terms directly to each certificate would make a credit issued in month eleven
# unreadable after rotation unless old keys are kept, which defeats rotating
# them. With an envelope, rotation only invalidates the wrapped keys: those can
# be rewrapped for the new certificates without re-encrypting the terms and
# without changing the commitment.
#
# THE COMMITMENT IS OVER THE CANONICAL PLAINTEXT, NOT THE CIPHERTEXT. CMS
# encryption is randomised, so the same terms encrypt to different bytes every
# time. A commitment over ciphertext would be useless for proving two parties
# hold the same terms.
#
# Usage:
#   bash tools/terms-seal.sh <terms.json> <org-slug> [org-slug ...]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tools/lib/env.sh" 2>/dev/null || true
env_init "$REPO" 2>/dev/null || { ENV_CONFIG_DIR="$REPO/network/config/local"; }

PKI="$REPO/network/pki/out"
SRC="${1:?usage: terms-seal.sh <terms.json> <org-slug> [org-slug ...]}"
shift
[[ $# -ge 1 ]] || { echo "at least one recipient organisation is required"; exit 1; }

OUT_DIR="$ENV_CONFIG_DIR/terms"
mkdir -p "$OUT_DIR"

# Canonical form first. jq -S sorts keys and -c strips whitespace, so the same
# terms always produce the same bytes and therefore the same commitment
# regardless of how they were written. Without this, two parties holding
# identical terms compute different hashes and the verification is theatre.
CANON="$(mktemp)"
trap 'rm -f "$CANON"' EXIT
jq -Sc '.' "$SRC" > "$CANON"

COMMITMENT="$(cast keccak "$(cat "$CANON")")"
REF="$(jq -r '.reference // "unnamed"' "$CANON")"
SEALED="$OUT_DIR/$REF.cms"

certs=()
for slug in "$@"; do
  cert="$PKI/$slug/issued/terms/terms.cert.pem"
  [[ -f "$cert" ]] || { echo "no encryption certificate for $slug at $cert"; exit 1; }
  certs+=("$cert")
done

# -binary is mandatory. Without it OpenSSL treats the input as text and
# canonicalises line endings, so the decrypted bytes differ from the input and
# the commitment no longer matches. The failure appears at verification time,
# far from its cause.
openssl cms -encrypt -binary -aes-256-gcm \
  -in "$CANON" -out "$SEALED" -outform DER \
  "${certs[@]}"

echo "sealed $REF"
echo "  recipients  $*"
echo "  sealed      $SEALED"
echo "  commitment  $COMMITMENT"
echo
echo "Put the commitment on chain as termsHash. The plaintext goes nowhere."
