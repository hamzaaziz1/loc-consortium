#!/usr/bin/env bash
#
# Environment-aware: LOC_ENV selects local (default) or staging.
#
# Asserts that the consortium network is healthy, not merely running.
#
# Containers can be up while the chain is stalled, while nodes disagree on the
# validator set, or while the EVM is missing opcodes the compiler emits. Each
# of those looks fine in `docker compose ps` and breaks everything downstream.
#
# Every RPC endpoint requires mutual TLS, so this test authenticates with the
# operator's dedicated health-check certificate. It deliberately does not reuse
# the controller certificate: that one can change who may connect to the
# network, and a test harness has no business holding it.
#
# Uses curl and jq rather than cast, so CI needs no Solidity toolchain.
#
# Run:  make smoke
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tools/lib/addressing.sh"
source "$REPO/tools/lib/env.sh"
env_init "$REPO"
addr_load "$ENV_ADDRESSING" || exit 1

GENESIS="$ENV_GENESIS"
MANIFEST="$ENV_MANIFEST"
PKI="$REPO/network/pki/out"
HOST="${SMOKE_HOST:-127.0.0.1}"

CA="$PKI/root/certs/root.cert.pem"
CLIENT_CHAIN="$PKI/operator/issued/smoke/smoke.chain.pem"
CLIENT_KEY="$PKI/operator/issued/smoke/smoke.key.pem"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

for f in "$GENESIS" "$MANIFEST" "$CA" "$CLIENT_CHAIN" "$CLIENT_KEY"; do
  [[ -f "$f" ]] || { echo "missing $f"; echo "run: make pki && make network-keys && make network-config"; exit 1; }
done

# JSON-RPC over mutual TLS. $1 method, $2 params JSON, $3 node name, $4 port.
#
# --resolve maps the certificate's name to loopback, so hostname verification
# is exercised rather than bypassed: the server certificate asserts
# <node>.loc.consortium and curl checks it, while connecting to 127.0.0.1.
#
# --http1.1 because Besu's JSON-RPC is an HTTP/1.1 service; curl will otherwise
# negotiate h2 over TLS and the request fails after a successful handshake.
#
# The client presents its chain, not its bare certificate. The server trusts
# only the root, so the intermediate has to come from the client for a path to
# exist.
rpc() {
  local method="$1" params="$2" node="$3" port="$4"
  curl -s --http1.1 --max-time 10 \
    --resolve "${node}.loc.consortium:${port}:${HOST}" \
    --cacert "$CA" --cert "$CLIENT_CHAIN" --key "$CLIENT_KEY" \
    -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "https://${node}.loc.consortium:${port}" 2>/dev/null
}
rpc_result() { rpc "$@" | jq -r '.result // empty' 2>/dev/null; }
hex2dec() { printf '%d' "$1" 2>/dev/null || echo 0; }

EXPECTED_CHAIN_ID="$(jq -r '.config.chainId' "$GENESIS")"
NODE_COUNT="${#ADDR_NODES[@]}"
EXPECTED_PEERS=$(( NODE_COUNT - 1 ))

# Reachability is tracked so an unreachable node is reported once rather than
# failing every subsequent check as if it disagreed about something.
declare -a REACHABLE

# Wait for the first node to answer before asserting anything. Nothing in this
# stack waits for what it depends on: a node is "healthy" to Docker before its
# RPC listener is up, and CI runners are slower than a laptop. Without this the
# suite fails on timing and the output looks identical to a broken network.
echo "0. waiting for the network to answer"
READY=0
for _ in $(seq 1 30); do
  if [[ -n "$(rpc_result eth_chainId '[]' "${ADDR_NODES[0]}" "${ADDR_RPC_PORTS[0]}")" ]]; then
    READY=1
    break
  fi
  sleep 2
done
if [[ "$READY" -eq 1 ]]; then
  ok "${ADDR_NODES[0]} answered"
else
  bad "no node answered within 60s"
fi

echo "1. every node answers over mutual TLS and is on the right chain"
for i in "${!ADDR_NODES[@]}"; do
  node="${ADDR_NODES[$i]}"; port="${ADDR_RPC_PORTS[$i]}"
  got="$(rpc_result eth_chainId '[]' "$node" "$port")"
  if [[ -z "$got" ]]; then
    REACHABLE[$i]=0
    bad "$node unreachable on port $port (TLS handshake or node down)"
  elif [[ "$(hex2dec "$got")" == "$EXPECTED_CHAIN_ID" ]]; then
    REACHABLE[$i]=1
    ok "$node on chain $EXPECTED_CHAIN_ID"
  else
    REACHABLE[$i]=1
    bad "$node reports chain $(hex2dec "$got"), expected $EXPECTED_CHAIN_ID"
  fi
done

echo "2. the full mesh formed"
for i in "${!ADDR_NODES[@]}"; do
  [[ "${REACHABLE[$i]}" -eq 1 ]] || { echo "  SKIP  ${ADDR_NODES[$i]} unreachable"; continue; }
  n="$(hex2dec "$(rpc_result net_peerCount '[]' "${ADDR_NODES[$i]}" "${ADDR_RPC_PORTS[$i]}")")"
  if [[ "$n" -eq "$EXPECTED_PEERS" ]]; then
    ok "${ADDR_NODES[$i]} has $n peers"
  else
    bad "${ADDR_NODES[$i]} has $n peers, expected $EXPECTED_PEERS"
  fi
done

echo "3. every node agrees on the validator set"
EXPECTED_VALIDATORS="$(jq -r '[.nodes[] | select(.role=="validator") | .address] | sort | join(",")' "$MANIFEST")"
for i in "${!ADDR_NODES[@]}"; do
  [[ "${REACHABLE[$i]}" -eq 1 ]] || { echo "  SKIP  ${ADDR_NODES[$i]} unreachable"; continue; }
  got="$(rpc qbft_getValidatorsByBlockNumber '["latest"]' "${ADDR_NODES[$i]}" "${ADDR_RPC_PORTS[$i]}" \
         | jq -r '[.result[]?] | sort | join(",")')"
  if [[ "$got" == "$EXPECTED_VALIDATORS" ]]; then
    ok "${ADDR_NODES[$i]} agrees on the validator set"
  else
    bad "${ADDR_NODES[$i]} validator set differs from the genesis"
    echo "        expected: $EXPECTED_VALIDATORS"
    echo "        got:      $got"
  fi
done

# Everything below needs at least one reachable node.
FIRST=-1
for i in "${!ADDR_NODES[@]}"; do
  [[ "${REACHABLE[$i]}" -eq 1 ]] && { FIRST=$i; break; }
done
if [[ "$FIRST" -lt 0 ]]; then
  echo
  echo "no node is reachable; skipping chain checks"
  echo "$pass passed, $fail failed"
  exit 1
fi
FNODE="${ADDR_NODES[$FIRST]}"; FPORT="${ADDR_RPC_PORTS[$FIRST]}"

echo "4. the chain is advancing"
h1="$(hex2dec "$(rpc_result eth_blockNumber '[]' "$FNODE" "$FPORT")")"
sleep 8
h2="$(hex2dec "$(rpc_result eth_blockNumber '[]' "$FNODE" "$FPORT")")"
if [[ "$h2" -gt "$h1" ]]; then
  ok "height went $h1 -> $h2 in 8s"
else
  bad "height stuck at $h1 after 8s: consensus is not progressing"
fi

echo "5. all nodes share one chain"
# Immediate finality means forks are impossible. Checking a few blocks back
# avoids racing nodes that are momentarily a block apart.
TARGET=$(( h1 > 3 ? h1 - 3 : 1 ))
TARGET_HEX="$(printf '0x%x' "$TARGET")"
REF=""; agreed=1
for i in "${!ADDR_NODES[@]}"; do
  [[ "${REACHABLE[$i]}" -eq 1 ]] || continue
  hash="$(rpc eth_getBlockByNumber "[\"$TARGET_HEX\",false]" "${ADDR_NODES[$i]}" "${ADDR_RPC_PORTS[$i]}" \
          | jq -r '.result.hash // empty')"
  if [[ -z "$REF" ]]; then REF="$hash"; continue; fi
  [[ "$hash" == "$REF" ]] || { agreed=0; bad "${ADDR_NODES[$i]} has a different block $TARGET"; }
done
[[ "$agreed" -eq 1 ]] && ok "all reachable nodes agree on block $TARGET"

echo "6. the EVM has the opcodes the compiler emits"
# PUSH0, PUSH0, RETURN. Arrived with Shanghai, and solc emits it at the version
# pinned in contracts/foundry.toml. If shanghaiTime did not take effect the
# chain runs perfectly and every contract fails at call time, which is the
# failure ADR 0002 predicted.
out="$(rpc eth_call '[{"to":null,"data":"0x5f5ff3"},"latest"]' "$FNODE" "$FPORT")"
if [[ "$(echo "$out" | jq -r '.result // empty')" == "0x" ]]; then
  ok "PUSH0 executes, Shanghai is active"
else
  bad "PUSH0 failed: $(echo "$out" | jq -r '.error.message // .result // "no response"')"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
