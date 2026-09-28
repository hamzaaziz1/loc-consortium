#!/usr/bin/env bash
#
# Generates the consortium root CA: one EC P-256 key pair, a self-signed
# certificate, and the openssl CA database used to track issuance and
# revocation.
#
# Safe to read before running. It writes only inside network/pki/out/root,
# which is gitignored, and refuses to overwrite an existing root.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_OUT="$PKI_DIR/out/root"

# Distinguished name for the root. C must match every intermediate's country,
# because the signing policy in root.cnf requires it.
export CERT_C="GB"
export CERT_O="LoC Consortium"
export CERT_OU="PKI"
export CERT_CN="LoC Consortium Root CA"

ROOT_KEY="$PKI_OUT/private/root.key.pem"
ROOT_CERT="$PKI_OUT/certs/root.cert.pem"

if [[ -f "$ROOT_CERT" && "${FORCE:-0}" != "1" ]]; then
  echo "root CA already exists at $ROOT_CERT"
  echo "regenerating it invalidates every certificate beneath it."
  echo "if you are sure: FORCE=1 $0"
  exit 1
fi

if [[ "${FORCE:-0}" == "1" ]]; then
  rm -rf "$PKI_OUT"
fi

echo "==> creating CA directory structure"
mkdir -p "$PKI_OUT"/{certs,crl,newcerts,private}
chmod 700 "$PKI_OUT/private"

# index.txt is the issuance ledger. serial and crlnumber are counters openssl
# increments itself. Starting at 1000 rather than 1 is conventional and avoids
# single-digit serials, which some tooling handles badly.
touch "$PKI_OUT/index.txt"
[[ -f "$PKI_OUT/serial"    ]] || echo 1000 > "$PKI_OUT/serial"
[[ -f "$PKI_OUT/crlnumber" ]] || echo 1000 > "$PKI_OUT/crlnumber"

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
