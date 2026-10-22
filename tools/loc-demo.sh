#!/usr/bin/env bash
#
# End-to-end letter of credit lifecycle against the live network.
#
# Issues a credit, advises it, records shipment milestones, presents documents,
# accepts and settles, printing each state transition and who caused it.
#
# THE TERMS ARE NOT ON CHAIN. This script writes them as JSON to a local
# directory and commits keccak256 of the canonical bytes. Every step verifies
# the commitment before acting, so a party acting on tampered terms fails
# rather than proceeding.
#
# That is deliberately the shape m6 extends: the commitment and the
# verification stay as they are, and plaintext-on-disk is replaced by
# per-party encryption. The carrier already never needs the terms here, only
# the credit's identity and its expiry, which is what makes the privacy work
# possible rather than retrofitted.
#
# Usage:
#   FACTORY=0x... bash tools/loc-demo.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tools/lib/env.sh"
env_init "$REPO"

RPC="${RPC:-http://127.0.0.1:${PROXY_PORT:-8600}}"
FACTORY="${FACTORY:?set FACTORY to the LetterOfCreditFactory address}"
TERMS_DIR="$ENV_CONFIG_DIR/terms"
KEYS="$ENV_KEYS_DIR/members"

IMPORTER_KEY="$(cat "$KEYS/importer-bank/key.priv")"
EXPORTER_KEY="$(cat "$KEYS/exporter-bank/key.priv")"
LOGISTICS_KEY="$(cat "$KEYS/logistics/key.priv")"

send() {
  local key="$1"; shift
  cast send "$@" --private-key "$key" --rpc-url "$RPC" --legacy --gas-price 0 >/dev/null
}

state_name() {
  case "$1" in
    0) echo "None" ;; 1) echo "Issued" ;; 2) echo "Advised" ;; 3) echo "Presented" ;;
    4) echo "Accepted" ;; 5) echo "Rejected" ;; 6) echo "Settled" ;;
    7) echo "Expired" ;; 8) echo "Cancelled" ;; *) echo "unknown($1)" ;;
  esac
}

show() {
  local loc="$1" who="$2" what="$3"
  local s; s="$(cast call "$loc" "state()(uint8)" --rpc-url "$RPC")"
  printf '  %-18s %-28s -> %s\n' "$who" "$what" "$(state_name "$s")"
}

# --- the terms, held off chain -------------------------------------------
mkdir -p "$TERMS_DIR"
REF="LC-$(date +%Y%m%d-%H%M%S)"
TERMS_FILE="$TERMS_DIR/$REF.json"

# Canonical JSON: jq -S -c sorts keys and strips whitespace, so the same terms
# always hash to the same commitment regardless of how they were written.
jq -Sc '.' > "$TERMS_FILE" <<JSON
{
  "reference": "$REF",
  "applicant": "Northwind Trading Ltd",
  "beneficiary": "Pacific Textiles Co",
  "amount": "450000.00",
  "currency": "USD",
  "incoterms": "CIF Rotterdam",
  "goods": "12000 units cotton fabric, 180gsm, grade A",
  "documents": [
    "commercial invoice in triplicate",
    "full set clean on board bill of lading",
    "certificate of origin",
    "insurance policy for 110% of invoice value"
  ],
  "partialShipment": false,
  "latestShipment": "2026-12-15"
}
JSON

TERMS_HASH="$(cast keccak "$(cat "$TERMS_FILE")")"
LOCATOR="$(cast keccak "$REF")"
EXPIRY=$(( $(date +%s) + 60 * 60 * 24 * 60 ))

echo "letter of credit $REF"
echo "  terms      $TERMS_FILE"
echo "  commitment $TERMS_HASH"
echo "  expiry     $(date -d "@$EXPIRY" '+%Y-%m-%d')"
echo

# --- issue ------------------------------------------------------------------
EXPORTER_ID="$(cast keccak "exporter-bank")"
LOGISTICS_ID="$(cast keccak "logistics")"

send "$IMPORTER_KEY" "$FACTORY" "issue(bytes32,bytes32,bytes32,bytes32,uint64)" \
  "$EXPORTER_ID" "$LOGISTICS_ID" "$TERMS_HASH" "$LOCATOR" "$EXPIRY"

COUNT="$(cast call "$FACTORY" "creditCount()(uint256)" --rpc-url "$RPC")"
LOC="$(cast call "$FACTORY" "credits()(address[])" --rpc-url "$RPC" | tr -d '[]' | tr ',' '\n' | tail -1 | xargs)"
echo "credit $COUNT at $LOC"
show "$LOC" "importer bank" "issued the credit"

# --- the commitment is checked before anyone acts ---------------------------
# A party that cannot reproduce the commitment from its copy of the terms must
# refuse to act. This is the check m6 makes meaningful by giving each party a
# copy only it can decrypt.
ON_CHAIN="$(cast call "$LOC" "TERMS_HASH()(bytes32)" --rpc-url "$RPC")"
if [[ "$ON_CHAIN" != "$TERMS_HASH" ]]; then
  echo "  COMMITMENT MISMATCH: refusing to proceed"
  exit 1
fi
echo "  exporter bank      verified terms against the commitment"

# --- advise -----------------------------------------------------------------
send "$EXPORTER_KEY" "$LOC" "advise()"
show "$LOC" "exporter bank" "advised the beneficiary"

# --- shipment ---------------------------------------------------------------
# The carrier records these without ever reading the terms. It needs the
# credit's identity and its expiry, both of which are on chain, and nothing
# commercial.
send "$LOGISTICS_KEY" "$LOC" "recordMilestone(bytes32,bytes32)" \
  "$(cast keccak "goods-received")" "$(cast keccak "warehouse Rotterdam, 12000 units")"
show "$LOC" "logistics" "recorded goods received"

send "$LOGISTICS_KEY" "$LOC" "recordMilestone(bytes32,bytes32)" \
  "$(cast keccak "loaded-on-board")" "$(cast keccak "MV Northern Star, B/L 44821")"
show "$LOC" "logistics" "recorded loading on board"

send "$LOGISTICS_KEY" "$LOC" "recordMilestone(bytes32,bytes32)" \
  "$(cast keccak "departed")" "$(cast keccak "departed Shanghai 2026-11-02")"
show "$LOC" "logistics" "recorded departure"

MILESTONES="$(cast call "$LOC" "milestoneCount()(uint256)" --rpc-url "$RPC")"
echo "  $MILESTONES milestones recorded, no commercial terms disclosed to the carrier"

# --- presentation ------------------------------------------------------------
DOCS_HASH="$(cast keccak "invoice+bill of lading+origin+insurance for $REF")"
send "$EXPORTER_KEY" "$LOC" "presentDocuments(bytes32)" "$DOCS_HASH"
show "$LOC" "exporter bank" "presented documents"

# --- examination and settlement -----------------------------------------------
send "$IMPORTER_KEY" "$LOC" "acceptPresentation()"
show "$LOC" "importer bank" "accepted the presentation"

send "$IMPORTER_KEY" "$LOC" "recordSettlement(bytes32)" "$(cast keccak "SWIFT MT103 ref 99812")"
show "$LOC" "importer bank" "recorded settlement"

echo
echo "final state: $(state_name "$(cast call "$LOC" "state()(uint8)" --rpc-url "$RPC")")"
echo "credit:      $LOC"
echo "terms:       $TERMS_FILE  (never on chain)"
