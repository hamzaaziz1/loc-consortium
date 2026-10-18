#!/usr/bin/env bash
#
# Produces network/config/deploy.json: everything the deployment script needs
# about the founding consortium, joined from the files that already hold it.
#
#   orgs.conf        which organisations exist
#   manifest.json    each validator's block-signing address
#   addressing.conf  each node's IP, for the enode URL
#   member accounts  one EOA per organisation, generated here if absent
#
# The join happens once, here, rather than inside a Solidity script. Reading
# three files and matching across them in Solidity is possible and miserable,
# and a deployment is exactly the wrong place to discover a mismatch.
#
# Member accounts are the addresses an organisation votes with. They are
# distinct from its validator address: signing blocks and casting governance
# votes are different capabilities, and in a real deployment they would be held
# by different people on different hardware.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PKI_DIR="$REPO/network/pki"
source "$PKI_DIR/lib/common.sh"
source "$REPO/tools/lib/addressing.sh"
source "$REPO/tools/lib/env.sh"
env_init "$REPO"

MANIFEST="$ENV_MANIFEST"
MEMBER_KEYS="$ENV_KEYS_DIR/members"
OUT="$ENV_DEPLOY_CONFIG"
P2P_PORT=30303

[[ -f "$MANIFEST" ]] || { echo "no manifest. run ./tools/gen-network.sh first"; exit 1; }
command -v cast >/dev/null || { echo "cast (foundry) is required to generate member accounts"; exit 1; }
addr_load "$ENV_ADDRESSING"

ip_of() {
  local node="$1" i
  for i in "${!ADDR_NODES[@]}"; do
    [[ "${ADDR_NODES[$i]}" == "$node" ]] && { echo "${ADDR_IPS[$i]}"; return 0; }
  done
  return 1
}

mkdir -p "$MEMBER_KEYS" "$(dirname "$OUT")"

rows=()
emit_member() {
  local slug="$1" name="$2"
  local node="validator-1.${slug}"

  local validator pub ip enode key_file address
  validator="$(jq -r --arg n "$node" '.nodes[] | select(.node==$n) | .address // empty' "$MANIFEST")"
  pub="$(jq -r --arg n "$node" '.nodes[] | select(.node==$n) | .pubkey // empty' "$MANIFEST")"
  [[ -n "$validator" ]] || { echo "no validator entry for $node in the manifest" >&2; exit 1; }
  ip="$(ip_of "$node")" || { echo "no address for $node in addressing.conf" >&2; exit 1; }
  enode="enode://${pub#0x}@${ip}:${P2P_PORT}"

  # One governance account per organisation. Generated rather than committed,
  # like every other key in this repository, and gitignored.
  key_file="$MEMBER_KEYS/$slug/key.priv"
  if [[ ! -f "$key_file" ]]; then
    mkdir -p "$MEMBER_KEYS/$slug"
    cast wallet new --json 2>/dev/null \
      | jq -r '.[0].private_key' > "$key_file"
    chmod 400 "$key_file"
  fi
  address="$(cast wallet address --private-key "$(cat "$key_file")")"

  printf '    %-16s validator %s  account %s\n' "$slug" "$validator" "$address"
  rows+=("$(jq -nc \
    --arg slug "$slug" --arg name "$name" \
    --arg validator "$validator" --arg account "$address" --arg enode "$enode" \
    '{slug:$slug,name:$name,validator:$validator,account:$account,enode:$enode}')")
}

echo "==> [$ENV_NAME] joining founding consortium"
for_each_org emit_member

# An explicit count rather than relying on the JSON reader to measure the
# array: forge's JSON path support does not reliably expose array length, and
# a deployment is the wrong place to find that out.
printf '%s\n' "${rows[@]}" | jq -s '{count: length, members: .}' > "$OUT"
echo
echo "wrote $OUT"
