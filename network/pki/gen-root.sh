#!/usr/bin/env bash
#
# Generates the consortium root CA: one EC P-256 key pair, a self-signed
# certificate, and the openssl CA database used to track issuance and
# revocation.
#
# Writes only inside network/pki/out/root, which is gitignored, and refuses to
# overwrite an existing root unless FORCE=1.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_DIR
source "$PKI_DIR/lib/common.sh"

export PKI_OUT="$PKI_DIR/out/root"
ROOT_KEY="$PKI_OUT/private/root.key.pem"
ROOT_CERT="$PKI_OUT/certs/root.cert.pem"

if [[ -f "$ROOT_CERT" && "${FORCE:-0}" != "1" ]]; then
  echo "root CA already exists at $ROOT_CERT"
  echo "regenerating it invalidates every certificate beneath it."
  echo "if you are sure: FORCE=1 $0"
  exit 1
fi

# Key material is written read-only, so a regeneration cannot overwrite in
# place and has to delete first. A regenerated root is also a new authority,
# so it starts with an empty issuance ledger rather than inheriting one.
if [[ "${FORCE:-0}" == "1" ]]; then
  rm -rf "$PKI_OUT"
fi

echo "==> creating CA directory structure"
ca_dir_init "$PKI_OUT"

echo "==> generating root private key (EC P-256)"
# EC P-256 rather than RSA: universally supported by the JVM that Besu runs on,
# much cheaper handshakes, and far smaller key material. Nodes reconnect often
# on a peer-to-peer network, so handshake cost is not theoretical here.
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "$ROOT_KEY"
chmod 400 "$ROOT_KEY"

echo "==> self-signing root certificate (10 years)"
# 10 years because rotating a root means re-establishing trust on every node in
# the consortium. Long life is the correct trade only because the key is used
# rarely and is meant to be kept offline. See ADR 0003.
openssl req \
  -config "$PKI_DIR/openssl/root.cnf" \
  -key "$ROOT_KEY" \
  -new -x509 \
  -days 3650 \
  -sha256 \
  -extensions v3_root_ca \
  -out "$ROOT_CERT"
chmod 444 "$ROOT_CERT"

echo
echo "root CA created:"
echo "  key  $ROOT_KEY"
echo "  cert $ROOT_CERT"
