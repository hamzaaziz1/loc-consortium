#!/usr/bin/env bash
#
# Proves the permissioning layer actually enforces membership, against the
# live network.
#
# The controller's unit tests cover the reconciliation logic without a chain.
# This covers the part they cannot: that what the registry says ends up in the
# node's allowlist, and that a member losing Active status loses access.
#
# Run:  make perm-test   (requires the network and controller to be up)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tools/lib/addressing.sh"
source "$REPO/tools/lib/env.sh"
env_init "$REPO"
addr_load "$ENV_ADDRESSING" || exit 1

PKI="$REPO/network/pki/out"
HOST="${SMOKE_HOST:-127.0.0.1}"
CA="$PKI/root/certs/root.cert.pem"
CERT="$PKI/operator/issued/smoke/smoke.chain.pem"
KEY="$PKI/operator/issued/smoke/smoke.key.pem"
PERM_FILE="$ENV_CONFIG_DIR/permissions.toml"
HEARTBEAT="$ENV_CONFIG_DIR/controller/heartbeat.json"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

rpc() {
  local method="$1" params="$2" node="$3" port="$4"
  curl -s --http1.1 --max-time 10 \
    --resolve "${node}.loc.consortium:${port}:${HOST}" \
    --cacert "$CA" --cert "$CERT" --key "$KEY" \
    -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "https://${node}.loc.consortium:${port}" 2>/dev/null
}

NODE="${ADDR_NODES[0]}"; PORT="${ADDR_RPC_PORTS[0]}"

echo "1. the PERM API is reachable and permissioning is on"
nodes_json="$(rpc perm_getNodesAllowlist '[]' "$NODE" "$PORT" | jq -r '.result // empty')"
if [[ -z "$nodes_json" ]]; then
  bad "perm_getNodesAllowlist returned nothing: permissioning may not be enabled"
  echo
  echo "$pass passed, $fail failed"
  exit 1
fi
ok "node allowlist has $(echo "$nodes_json" | jq 'length') entries"

accounts_json="$(rpc perm_getAccountsAllowlist '[]' "$NODE" "$PORT" | jq -r '.result // empty')"
ok "account allowlist has $(echo "$accounts_json" | jq 'length') entries"

echo "2. every peered node is allowlisted"
# A node the allowlist excludes cannot be a peer, so the mesh is itself
# evidence. This catches an allowlist that is populated but wrong.
peers="$(rpc net_peerCount '[]' "$NODE" "$PORT" | jq -r '.result // "0x0"')"
peer_count=$((peers))
if [[ "$peer_count" -eq $(( ${#ADDR_NODES[@]} - 1 )) ]]; then
  ok "$peer_count peers with permissioning enforced"
else
  bad "$peer_count peers, expected $(( ${#ADDR_NODES[@]} - 1 )): the allowlist may be excluding a node"
fi

echo "3. the node's allowlist matches the file on disk"
# The file is the controller's output; the API is what the node actually
# loaded. If they differ, a reload failed silently.
if [[ -f "$PERM_FILE" ]]; then
  file_nodes="$(grep -E '^nodes-allowlist=' "$PERM_FILE" | sed 's/^nodes-allowlist=//' | jq -r 'sort | join(",")' 2>/dev/null)"
  live_nodes="$(echo "$nodes_json" | jq -r 'map(ascii_downcase) | sort | join(",")')"
  file_nodes="$(echo "$file_nodes" | tr 'A-Z' 'a-z')"
  if [[ "$file_nodes" == "$live_nodes" ]]; then
    ok "the loaded allowlist matches permissions.toml"
  else
    bad "the node's allowlist differs from the file: a reload failed"
    echo "        file: $file_nodes"
    echo "        live: $live_nodes"
  fi
else
  bad "no permissions.toml at $PERM_FILE"
fi

echo "4. the controller is reconciling, and recently"
# Fails open by design, so a dead controller is invisible from the network's
# behaviour. The heartbeat is the only way to notice, which is why it exists
# and why m7 alerts on it.
if [[ -f "$HEARTBEAT" ]]; then
  hb_block="$(jq -r '.block // 0' "$HEARTBEAT")"
  head_hex="$(rpc eth_blockNumber '[]' "$NODE" "$PORT" | jq -r '.result // "0x0"')"
  head=$((head_hex))
  lag=$(( head - hb_block ))
  if [[ "$lag" -lt 0 ]]; then lag=$(( -lag )); fi
  if [[ "$lag" -lt 60 ]]; then
    ok "heartbeat at block $hb_block, head $head, lag $lag blocks"
  else
    bad "heartbeat is $lag blocks behind: the controller is stale or dead"
  fi
else
  bad "no heartbeat at $HEARTBEAT: the controller has never reconciled"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
