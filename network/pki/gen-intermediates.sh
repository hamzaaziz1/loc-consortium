#!/usr/bin/env bash
#
# Generates one intermediate CA per consortium organisation, each signed by the
# root and constrained to its own namespace.
#
# Reads the membership list from openssl/orgs.conf. Adding a fifth member means
# editing that file and rerunning; existing intermediates are left alone.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_DIR
source "$PKI_DIR/lib/common.sh"

export PKI_OUT="$PKI_DIR/out/root"
ROOT_CERT="$PKI_OUT/certs/root.cert.pem"

if [[ ! -f "$ROOT_CERT" ]]; then
  echo "no root CA found at $ROOT_CERT"
  echo "run ./network/pki/gen-root.sh first"
  exit 1
fi

# The root was created before this setting existed, so make sure its database
# allows reissuing a subject before we sign anything with it.
ca_allow_reissue "$PKI_OUT"

gen_one() {
  local slug="$1" name="$2"

  export ORG_SLUG="$slug"
  export ORG_O="$name"
  export ORG_CN="$name Intermediate CA"
  export ORG_DOMAIN="${slug}.${DOMAIN_SUFFIX}"
  export ORG_OUT="$PKI_DIR/out/$slug"

  local key="$ORG_OUT/private/$slug.key.pem"
  local csr="$ORG_OUT/$slug.csr.pem"
  local cert="$ORG_OUT/certs/$slug.cert.pem"
  local chain="$ORG_OUT/certs/$slug.chain.pem"

  if [[ -f "$cert" && "${FORCE:-0}" != "1" ]]; then
    echo "==> $slug: already exists, skipping"
    return 0
  fi

  # A regenerated CA is a new authority, so it starts with an empty issuance
  # ledger. Keeping a stale index.txt would claim a history that does not
  # belong to this key.
  if [[ "${FORCE:-0}" == "1" ]]; then
    rm -rf "$ORG_OUT"
  fi

  echo "==> $slug ($name)"
  echo "    namespace: $ORG_DOMAIN"
  ca_dir_init "$ORG_OUT"

  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key"
  chmod 400 "$key"

  openssl req -config "$PKI_DIR/openssl/intermediate.cnf" \
    -new -key "$key" -out "$csr"

  # Signed with root.cnf as the CA, but extensions come from
  # intermediate.cnf. The name constraints are therefore chosen by the root,
  # not requested by the member.
  openssl ca -batch \
    -config "$PKI_DIR/openssl/root.cnf" \
    -extfile "$PKI_DIR/openssl/intermediate.cnf" \
    -extensions v3_intermediate_ca \
    -days 1825 -notext -md sha256 \
    -in "$csr" -out "$cert" >/dev/null 2>&1
  chmod 444 "$cert"

  # A chain file: this intermediate followed by the root. Servers present the
  # chain so a peer can build a path to the root without fetching anything.
  cat "$cert" "$ROOT_CERT" > "$chain"
  chmod 444 "$chain"

  openssl verify -CAfile "$ROOT_CERT" "$cert" >/dev/null
  echo "    signed and verified against root"
}

for_each_org gen_one

echo
echo "intermediates:"
for_each_org_summary() {
  local slug="$1"
  local cert="$PKI_DIR/out/$slug/certs/$slug.cert.pem"
  printf '  %-14s %s\n' "$slug" "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"
}
for_each_org for_each_org_summary
