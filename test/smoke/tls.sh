#!/usr/bin/env bash
#
# Proves the RPC endpoints reject what they should, against the live network.
#
# The positive case is already covered by test/smoke/network.sh: a valid client
# certificate gets a JSON-RPC answer. That alone proves very little. An
# endpoint that accepts everything also accepts the right certificate.
#
# What matters is this: all four organisation CAs chain to the same root, so
# without name constraints any member could mint a certificate asserting
# another member's identity and every node would accept it. ADR 0003 says that
# path is closed. test/pki/name-constraints.sh shows openssl agrees. This shows
# the running network enforces it during the TLS handshake, which is a
# different and stronger claim.
#
# Run:  make tls-test     (requires the network to be up)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tools/lib/addressing.sh"
source "$REPO/network/pki/lib/common.sh"
source "$REPO/tools/lib/env.sh"
env_init "$REPO"
addr_load "$ENV_ADDRESSING" || exit 1

PKI="$REPO/network/pki/out"
export PKI_DIR="$REPO/network/pki"
HOST="${SMOKE_HOST:-127.0.0.1}"
CA="$PKI/root/certs/root.cert.pem"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Pick two different nodes so hostname verification can be tested by pointing
# one node's name at another node's port.
node_port() {
  local want="$1" i
  for i in "${!ADDR_NODES[@]}"; do
    [[ "${ADDR_NODES[$i]}" == "$want" ]] && { echo "${ADDR_RPC_PORTS[$i]}"; return 0; }
  done
  return 1
}
NODE_A="rpc-1.operator"; PORT_A="$(node_port "$NODE_A")" || { echo "rpc-1.operator not in addressing.conf"; exit 1; }
NODE_B="rpc-2.operator"; PORT_B="$(node_port "$NODE_B")" || { echo "rpc-2.operator not in addressing.conf"; exit 1; }

REQ='{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'

# Returns curl's exit code; output goes to $LAST_OUT.
try() {
  LAST_OUT="$(curl -s --http1.1 --max-time 8 "$@" \
    -X POST -H 'content-type: application/json' --data "$REQ" 2>&1)"
  return $?
}

echo "0. control: a valid client certificate is accepted"
# Without this, every other result below is meaningless: a network that is
# simply down would pass all the negative tests.
if try --resolve "${NODE_A}.loc.consortium:${PORT_A}:${HOST}" \
       --cacert "$CA" \
       --cert "$PKI/operator/issued/smoke/smoke.chain.pem" \
       --key  "$PKI/operator/issued/smoke/smoke.key.pem" \
       "https://${NODE_A}.loc.consortium:${PORT_A}" \
   && echo "$LAST_OUT" | grep -q '"result"'; then
  ok "valid client certificate gets an answer"
else
  echo "  the network is not answering valid clients; the rest is meaningless"
  echo "  $LAST_OUT"
  exit 1
fi

echo "1. plaintext HTTP is refused"
if try "http://${HOST}:${PORT_A}"; then
  bad "the endpoint answered an unencrypted request"
else
  ok "plaintext refused (curl $?)"
fi

echo "2. TLS without a client certificate is refused"
# This is the line between TLS and mutual TLS. If this passes, the endpoint is
# merely encrypted, not authenticated.
if try --resolve "${NODE_A}.loc.consortium:${PORT_A}:${HOST}" \
       --cacert "$CA" \
       "https://${NODE_A}.loc.consortium:${PORT_A}" \
   && echo "$LAST_OUT" | grep -q '"result"'; then
  bad "an anonymous client got an answer: client authentication is not enforced"
else
  ok "anonymous client refused"
fi

echo "3. a client certificate from an untrusted CA is refused"
# Chains to nothing the server knows. Distinct from the impersonation case
# below, where the chain IS trusted and the name is wrong.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
  -subj "/C=GB/O=Rogue Bank/OU=client/CN=client-1.importer-bank.loc.consortium" \
  -addext "subjectAltName=DNS:client-1.importer-bank.loc.consortium" \
  -days 1 -keyout "$WORK/rogue.key" -out "$WORK/rogue.crt" >/dev/null 2>&1
if try --resolve "${NODE_A}.loc.consortium:${PORT_A}:${HOST}" \
       --cacert "$CA" --cert "$WORK/rogue.crt" --key "$WORK/rogue.key" \
       "https://${NODE_A}.loc.consortium:${PORT_A}" \
   && echo "$LAST_OUT" | grep -q '"result"'; then
  bad "a self-signed client certificate was accepted"
else
  ok "untrusted client certificate refused"
fi

echo "4. one member cannot authenticate as another (ADR 0003, enforced live)"
# The importer bank's CA signs a certificate naming an exporter bank client.
# The signing succeeds, because a CA signs what its operator tells it to. The
# question is whether the network accepts the result.
#
# Note this writes an entry into the importer bank CA's issuance ledger, which
# is correct: a compromised CA would also have logged it. network/pki/out is
# generated and gitignored, so the pollution is not durable.
export ORG_SLUG=importer-bank
export ORG_O="Importer Bank"
export ORG_CN="Importer Bank Intermediate CA"
export ORG_DOMAIN="importer-bank.${DOMAIN_SUFFIX}"
export ORG_OUT="$PKI/importer-bank"
export LEAF_CN="client-9.exporter-bank.${DOMAIN_SUFFIX}"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK/evil.key" 2>/dev/null
openssl req -new -key "$WORK/evil.key" -out "$WORK/evil.csr" \
  -subj "/C=${CERT_C}/O=Importer Bank/OU=client/CN=${LEAF_CN}" 2>/dev/null
if ! openssl ca -batch -config "$PKI_DIR/openssl/intermediate.cnf" \
      -extfile "$PKI_DIR/openssl/leaf.cnf" -extensions v3_client \
      -days 1 -notext -md sha256 \
      -in "$WORK/evil.csr" -out "$WORK/evil.crt" >/dev/null 2>&1; then
  bad "could not mint the impersonating certificate; test inconclusive"
else
  ok "the importer bank CA signed it (as a compromised CA would)"
  cat "$WORK/evil.crt" "$PKI/importer-bank/certs/importer-bank.cert.pem" > "$WORK/evil.chain.pem"
  if try --resolve "${NODE_A}.loc.consortium:${PORT_A}:${HOST}" \
         --cacert "$CA" --cert "$WORK/evil.chain.pem" --key "$WORK/evil.key" \
         "https://${NODE_A}.loc.consortium:${PORT_A}" \
     && echo "$LAST_OUT" | grep -q '"result"'; then
    bad "the network accepted one member impersonating another"
  else
    ok "the network refused it: name constraints enforced during the handshake"
  fi
fi

echo "5. the server's own identity is verified"
# Point one node's name at a different node's port. The certificate that comes
# back is valid and trusted, it is simply the wrong node. A client that accepts
# this is trusting whatever answers the address.
if try --resolve "${NODE_B}.loc.consortium:${PORT_A}:${HOST}" \
       --cacert "$CA" \
       --cert "$PKI/operator/issued/smoke/smoke.chain.pem" \
       --key  "$PKI/operator/issued/smoke/smoke.key.pem" \
       "https://${NODE_B}.loc.consortium:${PORT_A}" \
   && echo "$LAST_OUT" | grep -q '"result"'; then
  bad "connected to $NODE_A while asking for $NODE_B: hostname not verified"
else
  ok "wrong hostname refused"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
