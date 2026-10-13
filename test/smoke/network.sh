#!/usr/bin/env bash
#
# Asserts that the consortium network is healthy, not merely running.
#
# Containers can be up while the chain is stalled, while nodes disagree on the
# validator set, or while the EVM is missing opcodes the compiler emits. Each
# of those looks fine in `docker compose ps` and breaks everything downstream,
# so each is checked explicitly.
#
# Uses curl and jq rather than cast, so CI needs no Solidity toolchain to run
# it.
#
# Run:  make smoke     (or bash test/smoke/network.sh)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tools/lib/addressing.sh"
addr_load "$REPO/network/config/addressing.conf" || exit 1

GENESIS="$REPO/network/genesis/genesis.json"
MANIFEST="$REPO/network/genesis/manifest.json"
HOST="${SMOKE_HOST:-127.0.0.1}"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

for f in "$GENESIS" "$MANIFEST"; do
  [[ -f "$f" ]] || { echo "missing $f. run make network-keys first"; exit 1; }
done

# JSON-RPC call. $1 method, $2 params as JSON, $3 host port.
rpc() {
  curl -s --max-time 10 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
    "http://${HOST}:$3" 2>/dev/null
}
rpc_result() { rpc "$@" | jq -r '.result // empty'; }

hex2dec() { printf '%d' "$1" 2>/dev/null || echo 0; }

EXPECTED_CHAIN_ID="$(jq -r '.config.chainId' "$GENESIS")"
NODE_COUNT="${#ADDR_NODES[@]}"
EXPECTED_PEERS=$(( NODE_COUNT - 1 ))

echo "1. every node answers and is on the right chain"
for i in "${!ADDR_NODES[@]}"; do
  port="${ADDR_RPC_PORTS[$i]}"
  got="$(rpc_result eth_chainId '[]' "$port")"
  if [[ -z "$got" ]]; then
    bad "${ADDR_NODES[$i]} did not answer on port $port"
  elif [[ "$(hex2dec "$got")" == "$EXPECTED_CHAIN_ID" ]]; then
    ok "${ADDR_NODES[$i]} on chain $EXPECTED_CHAIN_ID"
  else
    bad "${ADDR_NODES[$i]} reports chain $(hex2dec "$got"), expected $EXPECTED_CHAIN_ID"
  fi
done

echo "2. the full mesh formed"
# A node that is up but isolated produces no error anywhere. Peer count is the
# only cheap way to notice.
for i in "${!ADDR_NODES[@]}"; do
  got="$(rpc_result net_peerCount '[]' "${ADDR_RPC_PORTS[$i]}")"
  n="$(hex2dec "${got:-0x0}")"
  if [[ "$n" -eq "$EXPECTED_PEERS" ]]; then
    ok "${ADDR_NODES[$i]} has $n peers"
  else
    bad "${ADDR_NODES[$i]} has $n peers, expected $EXPECTED_PEERS"
  fi
done

echo "3. every node agrees on the validator set"
# The set each node reports must match the addresses recorded in the manifest,
# which are the addresses embedded in the genesis extraData. A node that
# disagrees will never finalise a block and the only symptom is silence.
EXPECTED_VALIDATORS="$(jq -r '[.nodes[] | select(.role=="validator") | .address] | sort | join(",")' "$MANIFEST")"
for i in "${!ADDR_NODES[@]}"; do
  got="$(rpc qbft_getValidatorsByBlockNumber '["latest"]' "${ADDR_RPC_PORTS[$i]}" \
         | jq -r '[.result[]?] | sort | join(",")')"
  if [[ "$got" == "$EXPECTED_VALIDATORS" ]]; then
    ok "${ADDR_NODES[$i]} agrees on the validator set"
  else
    bad "${ADDR_NODES[$i]} validator set differs from the genesis"
    echo "        expected: $EXPECTED_VALIDATORS"
    echo "        got:      $got"
  fi
done

echo "4. the chain is advancing"
FIRST_PORT="${ADDR_RPC_PORTS[0]}"
h1="$(hex2dec "$(rpc_result eth_blockNumber '[]' "$FIRST_PORT")")"
sleep 8
h2="$(hex2dec "$(rpc_result eth_blockNumber '[]' "$FIRST_PORT")")"
if [[ "$h2" -gt "$h1" ]]; then
  ok "height went $h1 -> $h2 in 8s"
else
  bad "height stuck at $h1 after 8s: consensus is not progressing"
fi

echo "5. all nodes share one chain"
# Immediate finality means no forks are possible. If two nodes report different
# hashes at the same height, something is very wrong, and checking a few blocks
# back avoids racing nodes that are a block apart.
TARGET=$(( h1 > 3 ? h1 - 3 : 1 ))
TARGET_HEX="$(printf '0x%x' "$TARGET")"
REF=""; agreed=1
for i in "${!ADDR_NODES[@]}"; do
  hash="$(rpc eth_getBlockByNumber "[\"$TARGET_HEX\",false]" "${ADDR_RPC_PORTS[$i]}" | jq -r '.result.hash // empty')"
  if [[ -z "$REF" ]]; then REF="$hash"; continue; fi
  [[ "$hash" == "$REF" ]] || { agreed=0; bad "${ADDR_NODES[$i]} has a different block $TARGET"; }
done
[[ "$agreed" -eq 1 ]] && ok "all nodes agree on block $TARGET"

echo "6. the EVM has the opcodes the compiler emits"
# PUSH0, PUSH0, RETURN. Arrived with Shanghai, and solc emits it at the version
# pinned in contracts/foundry.toml. If shanghaiTime did not take effect the
# chain still runs perfectly and every contract fails at call time, which is
# the exact failure ADR 0002 predicted.
out="$(rpc eth_call '[{"to":null,"data":"0x5f5ff3"},"latest"]' "$FIRST_PORT")"
if [[ "$(echo "$out" | jq -r '.result // empty')" == "0x" ]]; then
  ok "PUSH0 executes, Shanghai is active"
else
  bad "PUSH0 failed: $(echo "$out" | jq -r '.error.message // .result // "no response"')"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
