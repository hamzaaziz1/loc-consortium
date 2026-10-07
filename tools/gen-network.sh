#!/usr/bin/env bash
#
# Generates the QBFT genesis and the devp2p node keys for all six nodes.
#
# The genesis generator produces four validator keys and embeds their addresses
# in the genesis extraData. The two non-validator RPC nodes are not in that
# list, so their keys are generated separately here.
#
# Node keys are the devp2p identity, and for a validator the key that signs
# blocks. They are deliberately NOT stored with the TLS material in
# network/pki/out: same node, two separate cryptographic identities, and
# conflating them invites the assumption that one implies the other.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET="$REPO/network"
export PKI_DIR="$NET/pki"
source "$PKI_DIR/lib/common.sh"

BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:26.8.1}"
GEN_DIR="$NET/genesis"
KEYS_DIR="$NET/keys"
WORK="$GEN_DIR/.generated"

if [[ -f "$GEN_DIR/genesis.json" && "${FORCE:-0}" != "1" ]]; then
  echo "genesis already exists at $GEN_DIR/genesis.json"
  echo "regenerating changes every validator address and invalidates all chain data."
  echo "if you are sure: FORCE=1 $0"
  exit 1
fi

# Key files are written read-only, so regeneration must delete before writing.
rm -rf "$WORK" "$KEYS_DIR" "$GEN_DIR/genesis.json" "$GEN_DIR/manifest.json"
mkdir -p "$KEYS_DIR"

# --user makes the container write as you rather than as root. Without it every
# generated file is root-owned on the host and cleaning up needs sudo.
docker_besu() {
  docker run --rm --user "$(id -u):$(id -g)" "$@"
}

echo "==> generating QBFT genesis and validator keys"
# The generator refuses to write into a directory that already exists, so the
# parent is mounted and besu creates the leaf itself.
docker_besu \
  -v "$GEN_DIR":/cfg \
  -v "$GEN_DIR":/out \
  "$BESU_IMAGE" \
  operator generate-blockchain-config \
    --config-file=/cfg/qbft-config.json \
    --to=/out/.generated >/dev/null

mv "$WORK/genesis.json" "$GEN_DIR/genesis.json"

# --- read the node table, which is the same file the PKI issues certificates
# from, so node identities and certificate identities cannot drift apart.
read_nodes() {
  local role_filter="$1" name slug role kind
  while IFS='|' read -r name slug role kind || [[ -n "$name" ]]; do
    for v in name slug role kind; do
      local cur="${!v}"
      cur="${cur#"${cur%%[![:space:]]*}"}"
      cur="${cur%"${cur##*[![:space:]]}"}"
      printf -v "$v" '%s' "$cur"
    done
    [[ -z "$name" || "${name:0:1}" == "#" ]] && continue
    [[ "$kind" != "node" ]] && continue
    [[ "$role" != "$role_filter" ]] && continue
    echo "${name}.${slug}"
  done < "$PKI_DIR/openssl/nodes.conf"
}

mapfile -t VALIDATOR_NODES < <(read_nodes validator)
mapfile -t RPC_NODES       < <(read_nodes rpc)
mapfile -t GENERATED       < <(ls "$WORK/keys" | sort)

if [[ "${#VALIDATOR_NODES[@]}" -ne "${#GENERATED[@]}" ]]; then
  echo "mismatch: ${#VALIDATOR_NODES[@]} validators in nodes.conf, ${#GENERATED[@]} keys generated"
  echo "update blockchain.nodes.count in network/genesis/qbft-config.json"
  exit 1
fi

# The generated keys are named by address with no meaningful ordering, so they
# are sorted and assigned to validators in nodes.conf order. The assignment is
# arbitrary but recorded in the manifest, so it is stable for a given tree.
echo "==> assigning validator keys"
MANIFEST_ROWS=()
for i in "${!VALIDATOR_NODES[@]}"; do
  node="${VALIDATOR_NODES[$i]}"
  addr="${GENERATED[$i]}"
  dir="$KEYS_DIR/$node"
  mkdir -p "$dir"
  cp "$WORK/keys/$addr/key.priv" "$dir/key.priv"
  cp "$WORK/keys/$addr/key.pub"  "$dir/key.pub"
  echo "$addr" > "$dir/address"
  chmod 400 "$dir/key.priv"
  pub="$(cat "$dir/key.pub")"
  printf '    %-42s %s\n' "$node" "$addr"
  MANIFEST_ROWS+=("$(jq -nc --arg n "$node" --arg a "$addr" --arg p "$pub" --arg r validator \
    '{node:$n,role:$r,address:$a,pubkey:$p}')")
done

echo "==> generating RPC node keys"
for node in "${RPC_NODES[@]}"; do
  dir="$KEYS_DIR/$node"
  mkdir -p "$dir"
  # A node key is a 32-byte secp256k1 private key. Besu writes them 0x-prefixed
  # and will not accept bare hex, so the format is matched exactly.
  printf '0x%s\n' "$(openssl rand -hex 32)" > "$dir/key.priv"
  chmod 400 "$dir/key.priv"

  docker_besu -v "$dir":/k "$BESU_IMAGE" \
    public-key export --node-private-key-file=/k/key.priv --to=/k/key.pub >/dev/null

  pub="$(cat "$dir/key.pub")"
  printf '    %-42s (non-validator)\n' "$node"
  MANIFEST_ROWS+=("$(jq -nc --arg n "$node" --arg p "$pub" --arg r rpc \
    '{node:$n,role:$r,pubkey:$p}')")
done

printf '%s\n' "${MANIFEST_ROWS[@]}" | jq -s \
  --arg image "$BESU_IMAGE" \
  '{besu:$image, nodes:.}' > "$GEN_DIR/manifest.json"

rm -rf "$WORK"

echo
echo "genesis:  $GEN_DIR/genesis.json"
echo "manifest: $GEN_DIR/manifest.json"
echo "keys:     $KEYS_DIR/"
