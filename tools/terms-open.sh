#!/usr/bin/env bash
#
# Opens sealed terms as one organisation and verifies them against the
# commitment recorded on chain.
#
# The verification is the point. A party that cannot reproduce the on-chain
# commitment from its copy must refuse to act, because either it has the wrong
# terms or someone has altered them. Decrypting successfully is not enough.
#
# Usage:
#   bash tools/terms-open.sh <sealed.cms> <org-slug> [credit-address]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI="$REPO/network/pki/out"
SEALED="${1:?usage: terms-open.sh <sealed.cms> <org-slug> [credit-address]}"
SLUG="${2:?organisation slug required}"
CREDIT="${3:-}"
RPC="${RPC:-http://127.0.0.1:8600}"

CERT="$PKI/$SLUG/issued/terms/terms.cert.pem"
KEY="$PKI/$SLUG/issued/terms/terms.key.pem"
[[ -f "$CERT" ]] || { echo "no encryption certificate for $SLUG"; exit 1; }

PLAIN="$(openssl cms -decrypt -binary -inform DER -in "$SEALED" -recip "$CERT" -inkey "$KEY")"

if [[ -n "$CREDIT" ]]; then
  ON_CHAIN="$(cast call "$CREDIT" "TERMS_HASH()(bytes32)" --rpc-url "$RPC")"
  COMPUTED="$(cast keccak "$PLAIN")"
  if [[ "$ON_CHAIN" != "$COMPUTED" ]]; then
    echo "COMMITMENT MISMATCH for $CREDIT" >&2
    echo "  on chain $ON_CHAIN" >&2
    echo "  computed $COMPUTED" >&2
    exit 1
  fi
  echo "# verified against $CREDIT" >&2
fi

echo "$PLAIN"
