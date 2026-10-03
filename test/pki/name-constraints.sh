#!/usr/bin/env bash
#
# Proves the PKI controls from ADR 0003 are enforced, not merely configured.
#
# The central claim being tested: all four organisation CAs chain to the same
# root, so without name constraints any member could mint a certificate
# asserting another member's identity and every node would accept it. These
# tests show that path is closed.
#
# Run locally:  bash test/pki/name-constraints.sh
# Runs in CI against a CA tree generated from scratch.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKI="$REPO/network/pki"
export PKI_DIR="$PKI"
source "$PKI/lib/common.sh"

ROOT="$PKI/out/root/certs/root.cert.pem"
IMP_CA="$PKI/out/importer-bank/certs/importer-bank.cert.pem"
EXP_CA="$PKI/out/exporter-bank/certs/exporter-bank.cert.pem"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

if [[ ! -f "$ROOT" || ! -f "$IMP_CA" ]]; then
  echo "no CA tree found. run gen-root.sh, gen-intermediates.sh and gen-leaves.sh first"
  exit 1
fi

echo "1. a legitimate certificate validates"
LEGIT="$PKI/out/importer-bank/issued/validator-1/validator-1.cert.pem"
if openssl verify -CAfile "$ROOT" -untrusted "$IMP_CA" "$LEGIT" >/dev/null 2>&1; then
  ok "importer bank validator verifies against the root"
else
  bad "a legitimate certificate failed to verify"
fi

echo "2. one member's CA cannot issue a usable identity for another member"
# The importer bank's CA signs a certificate naming an exporter bank host.
# This simulates a compromised or malicious member CA. The signature itself
# succeeds, because a CA will sign what its operator tells it to. The point is
# that the result does not validate anywhere.
export ORG_SLUG=importer-bank ORG_O="Importer Bank" \
       ORG_CN="Importer Bank Intermediate CA" \
       ORG_DOMAIN="importer-bank.${DOMAIN_SUFFIX}" \
       ORG_OUT="$PKI/out/importer-bank" \
       LEAF_CN="validator-1.exporter-bank.${DOMAIN_SUFFIX}"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK/evil.key" 2>/dev/null
openssl req -new -key "$WORK/evil.key" -out "$WORK/evil.csr" \
  -subj "/C=${CERT_C}/O=Importer Bank/OU=validator/CN=${LEAF_CN}" 2>/dev/null

if openssl ca -batch -config "$PKI/openssl/intermediate.cnf" \
     -extfile "$PKI/openssl/leaf.cnf" -extensions v3_node \
     -days 365 -notext -md sha256 \
     -in "$WORK/evil.csr" -out "$WORK/evil.cert" >/dev/null 2>&1; then
  ok "the compromised CA did sign it (as expected)"
else
  bad "could not produce the impersonating certificate, test is inconclusive"
fi

if [[ -f "$WORK/evil.cert" ]]; then
  out="$(openssl verify -CAfile "$ROOT" -untrusted "$IMP_CA" "$WORK/evil.cert" 2>&1)"
  if echo "$out" | grep -qi "permitted subtree violation"; then
    ok "validation rejects it: permitted subtree violation"
  else
    bad "impersonating certificate was not rejected by name constraints"
    echo "        openssl said: $out"
  fi

  # Also confirm it is not rescued by presenting the real exporter bank CA.
  out2="$(openssl verify -CAfile "$ROOT" -untrusted "$EXP_CA" "$WORK/evil.cert" 2>&1)"
  if echo "$out2" | grep -qi "unable to get local issuer\|error"; then
    ok "it cannot be validated against the real exporter bank CA either"
  else
    bad "impersonating certificate validated under the exporter bank CA"
  fi
fi

echo "3. a CA refuses to sign for an organisation that is not its own"
# Distinct from the test above: here the requested subject organisation does
# not match the CA's, so the signing policy rejects it before a certificate
# exists at all.
openssl req -new -key "$WORK/evil.key" -out "$WORK/wrongorg.csr" \
  -subj "/C=${CERT_C}/O=Exporter Bank/OU=validator/CN=validator-9.importer-bank.${DOMAIN_SUFFIX}" 2>/dev/null
if openssl ca -batch -config "$PKI/openssl/intermediate.cnf" \
     -extfile "$PKI/openssl/leaf.cnf" -extensions v3_node \
     -days 365 -notext -md sha256 \
     -in "$WORK/wrongorg.csr" -out "$WORK/wrongorg.cert" >/dev/null 2>&1; then
  bad "the importer bank CA signed a certificate for Exporter Bank"
else
  ok "signing policy rejected a mismatched organisation"
fi

echo "4. issued certificates cannot act as CAs"
# copy_extensions = none means a requester cannot ask for CA powers, and
# pathlen:0 on every intermediate means they could not be granted anyway.
if openssl x509 -in "$LEGIT" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:FALSE"; then
  ok "leaf certificate is marked CA:FALSE"
else
  bad "leaf certificate is not marked CA:FALSE"
fi

echo "5. client certificates cannot impersonate a server"
CLIENT="$PKI/out/importer-bank/issued/client-1/client-1.cert.pem"
eku="$(openssl x509 -in "$CLIENT" -noout -ext extendedKeyUsage 2>/dev/null)"
if echo "$eku" | grep -q "Client Authentication" && ! echo "$eku" | grep -q "Server Authentication"; then
  ok "client certificate carries clientAuth only"
else
  bad "client certificate is not restricted to clientAuth"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
