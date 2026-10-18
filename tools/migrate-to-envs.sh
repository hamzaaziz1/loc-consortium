#!/usr/bin/env bash
#
# One-time migration: moves existing generated material under network/.../local/
#
# MOVES rather than regenerates, deliberately. The local chain holds real
# state and deployed governance contracts; regenerating would mint new
# validator addresses and orphan them.
#
# Safe to run twice: it skips anything already migrated.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET="$REPO/network"

move() {
  local from="$1" to="$2"
  if [[ -e "$from" && ! -e "$to" ]]; then
    mkdir -p "$(dirname "$to")"
    mv "$from" "$to"
    echo "  moved $(basename "$from")"
  fi
}

echo "==> genesis"
mkdir -p "$NET/genesis/local"
move "$NET/genesis/genesis.json"  "$NET/genesis/local/genesis.json"
move "$NET/genesis/manifest.json" "$NET/genesis/local/manifest.json"

echo "==> node keys"
mkdir -p "$NET/keys/local"
for d in "$NET/keys"/*/; do
  name="$(basename "$d")"
  [[ "$name" == "local" || "$name" == "staging" ]] && continue
  move "$d" "$NET/keys/local/$name"
done

echo "==> config"
mkdir -p "$NET/config/local"
move "$NET/config/static-nodes.json" "$NET/config/local/static-nodes.json"
move "$NET/config/deploy.json"       "$NET/config/local/deploy.json"
move "$NET/config/deployed.md"       "$NET/config/local/deployed.md"
# addressing.conf ships per environment in the repository, so an old top-level
# copy is redundant rather than something to preserve.
if [[ -f "$NET/config/addressing.conf" ]]; then
  rm -f "$NET/config/addressing.conf"
  echo "  removed the old top-level addressing.conf"
fi

echo "==> compose override"
move "$NET/compose/compose.addressing.yml" "$NET/compose/compose.local.yml"

echo
echo "done. verify with:  LOC_ENV=local bash test/smoke/network.sh"
