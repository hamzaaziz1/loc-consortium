#!/usr/bin/env bash
#
# Builds the PKCS12 keystores Besu needs for RPC TLS, plus one shared
# truststore.
#
# Besu will not read PEM files for TLS; it wants a Java keystore. So each node
# gets a keystore holding its private key and its certificate chain, and every
# node gets the same truststore.
#
# THE TRUSTSTORE CONTAINS THE ROOT ONLY, AND THAT IS DELIBERATE.
#
# A certificate used as a trust anchor has its own extensions taken as given
# rather than checked, because path validation starts at the anchor. If the
# four organisation intermediates were in the truststore, their nameConstraints
# would never be evaluated and the control from ADR 0003 would be silently
# disabled: every member could then impersonate every other, and the PKI tests
# would still pass because they validate against a root-only trust store.
#
# Root only means validation walks leaf, then intermediate, then root, and
# evaluates the constraints on the way. Clients present their own chain, which
# is why gen-leaves.sh writes a .chain.pem for each certificate.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_DIR
source "$PKI_DIR/lib/common.sh"

OUT="$PKI_DIR/out"
STORE_DIR="$OUT/keystores"
PW_FILE="$STORE_DIR/keystore.password"
ROOT_CERT="$OUT/root/certs/root.cert.pem"

[[ -f "$ROOT_CERT" ]] || { echo "no root CA. run gen-root.sh first"; exit 1; }

rm -rf "$STORE_DIR"
mkdir -p "$STORE_DIR"

# One password for all stores. Generated rather than hardcoded so it is never
# committed, and written to a file because Besu takes the password as a file
# path, not an argument: a password on a command line is visible in the process
# table to every user on the host.
#
# In production this comes from a secret manager and is mounted at runtime.
openssl rand -hex 24 > "$PW_FILE"
# World readable, deliberately. The Besu container runs as its own user whose
# uid will not generally match yours, and a 0400 file owned by the host user is
# simply unreadable inside the container. These are development keystores,
# generated locally and never committed. In production the keystore and its
# password arrive as mounted secrets owned by the runtime user, and this line
# is the thing that changes.
chmod 444 "$PW_FILE"
PW="$(cat "$PW_FILE")"

echo "==> node keystores"
make_keystore() {
  local name="$1" slug="$2" role="$3" kind="$4"
  [[ "$kind" == "node" ]] || return 0

  local issued="$OUT/$slug/issued/$name"
  local p12="$STORE_DIR/${name}.${slug}.p12"

  openssl pkcs12 -export \
    -inkey "$issued/$name.key.pem" \
    -in    "$issued/$name.cert.pem" \
    -certfile "$OUT/$slug/certs/$slug.cert.pem" \
    -name "${name}.${slug}.${DOMAIN_SUFFIX}" \
    -out "$p12" \
    -passout "pass:$PW"
  chmod 444 "$p12"
  printf '    %-46s %s\n' "${name}.${slug}.${DOMAIN_SUFFIX}" "$(basename "$p12")"
}

while IFS='|' read -r name slug role kind || [[ -n "${name:-}" ]]; do
  for v in name slug role kind; do
    cur="${!v}"
    cur="${cur#"${cur%%[![:space:]]*}"}"
    cur="${cur%"${cur##*[![:space:]]}"}"
    printf -v "$v" '%s' "$cur"
  done
  [[ -z "$name" || "${name:0:1}" == "#" ]] && continue
  make_keystore "$name" "$slug" "$role" "$kind"
done < "$PKI_DIR/openssl/nodes.conf"

echo "==> truststore (root only)"
openssl pkcs12 -export -nokeys \
  -in "$ROOT_CERT" \
  -name "loc-consortium-root" \
  -out "$STORE_DIR/truststore.p12" \
  -passout "pass:$PW"
chmod 444 "$STORE_DIR/truststore.p12"
echo "    truststore.p12"

echo
echo "keystores in $STORE_DIR"
