# Shared settings and helpers for the PKI scripts. Sourced, not executed.

# The root CA's distinguished name. Every intermediate must share countryName,
# because root.cnf's signing policy sets countryName = match.
export CERT_C="GB"
export CERT_O="LoC Consortium"
export CERT_OU="PKI"
export CERT_CN="LoC Consortium Root CA"

# Private DNS suffix for the consortium. Deliberately not a real TLD: these
# names resolve only inside the network and must never be confusable with a
# public DNS name.
export DOMAIN_SUFFIX="loc.consortium"

# Creates the directory layout and database files openssl ca expects.
# index.txt is the issuance ledger; serial and crlnumber are counters openssl
# increments itself. Without these, openssl ca refuses to run.
ca_dir_init() {
  local dir="$1"
  local d
  for d in certs crl newcerts private; do
    mkdir -p "$dir/$d"
  done
  chmod 700 "$dir/private"
  touch "$dir/index.txt"
  [[ -f "$dir/serial"    ]] || echo 1000 > "$dir/serial"
  [[ -f "$dir/crlnumber" ]] || echo 1000 > "$dir/crlnumber"
  ca_allow_reissue "$dir"
}

# openssl refuses to issue a second certificate for a subject that already has
# one. That blocks renewal and key rotation, both of which produce a new
# certificate with an identical subject.
#
# The setting that controls this is NOT read from the config file at signing
# time: it lives in index.txt.attr beside the database, and openssl writes that
# file with unique_subject = yes the first time it signs anything. So it has to
# be written before the first signature, not after.
ca_allow_reissue() {
  local dir="$1"
  if [[ ! -f "$dir/index.txt.attr" ]] || ! grep -q "unique_subject *= *no" "$dir/index.txt.attr"; then
    echo "unique_subject = no" > "$dir/index.txt.attr"
  fi
}

# Iterates the org table, calling the given function with (slug, name).
# Blank lines and comments are skipped; surrounding whitespace is trimmed with
# bash parameter expansion rather than xargs, which mangles apostrophes.
for_each_org() {
  local fn="$1" slug name
  while IFS='|' read -r slug name || [[ -n "$slug" ]]; do
    slug="${slug#"${slug%%[![:space:]]*}"}"
    slug="${slug%"${slug##*[![:space:]]}"}"
    [[ -z "$slug" || "${slug:0:1}" == "#" ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    "$fn" "$slug" "$name"
  done < "$PKI_DIR/openssl/orgs.conf"
}

# Looks up an organisation's full name from its slug. Fails loudly on an
# unknown slug rather than issuing a certificate for an organisation that is
# not a member.
org_name_for() {
  local want="$1" slug name
  while IFS='|' read -r slug name || [[ -n "$slug" ]]; do
    slug="${slug#"${slug%%[![:space:]]*}"}"; slug="${slug%"${slug##*[![:space:]]}"}"
    [[ -z "$slug" || "${slug:0:1}" == "#" ]] && continue
    if [[ "$slug" == "$want" ]]; then
      name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
      echo "$name"; return 0
    fi
  done < "$PKI_DIR/openssl/orgs.conf"
  echo "unknown organisation slug: $want" >&2
  return 1
}

# Issues one end-entity certificate from an organisation's intermediate CA.
#   $1 name  $2 org slug  $3 role  $4 kind (node|client)
issue_leaf() {
  local name="$1" slug="$2" role="$3" kind="$4"

  export ORG_SLUG="$slug"
  export ORG_O; ORG_O="$(org_name_for "$slug")"
  export ORG_CN="$ORG_O Intermediate CA"
  export ORG_DOMAIN="${slug}.${DOMAIN_SUFFIX}"
  export ORG_OUT="$PKI_DIR/out/$slug"
  export LEAF_CN="${name}.${slug}.${DOMAIN_SUFFIX}"

  local ext
  case "$kind" in
    node)   ext=v3_node ;;
    client) ext=v3_client ;;
    *) echo "unknown kind: $kind" >&2; return 1 ;;
  esac

  local dir="$PKI_DIR/out/$slug/issued/$name"
  mkdir -p "$dir"
  local key="$dir/$name.key.pem" csr="$dir/$name.csr.pem"
  local cert="$dir/$name.cert.pem" chain="$dir/$name.chain.pem"

  if [[ -f "$cert" && "${FORCE:-0}" != "1" ]]; then
    echo "    $LEAF_CN already exists, skipping"
    return 0
  fi
  rm -f "$key" "$csr" "$cert" "$chain"

  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key"
  chmod 400 "$key"

  openssl req -new -key "$key" -out "$csr" \
    -subj "/C=${CERT_C}/O=${ORG_O}/OU=${role}/CN=${LEAF_CN}"

  openssl ca -batch \
    -config "$PKI_DIR/openssl/intermediate.cnf" \
    -extfile "$PKI_DIR/openssl/leaf.cnf" \
    -extensions "$ext" \
    -days 365 -notext -md sha256 \
    -in "$csr" -out "$cert" >/dev/null 2>&1
  chmod 444 "$cert"

  # Chain presented on the wire: leaf, then issuing intermediate. The root is
  # deliberately not included; a peer must already trust it out of band.
  cat "$cert" "$PKI_DIR/out/$slug/certs/$slug.cert.pem" > "$chain"
  chmod 444 "$chain"

  openssl verify -CAfile "$PKI_DIR/out/root/certs/root.cert.pem" \
    -untrusted "$PKI_DIR/out/$slug/certs/$slug.cert.pem" "$cert" >/dev/null
  echo "    $LEAF_CN  ($role, $kind)"
}

# Iterates the node table, calling issue_leaf for each row.
for_each_node() {
  local name slug role kind
  while IFS='|' read -r name slug role kind || [[ -n "$name" ]]; do
    for v in name slug role kind; do
      local cur="${!v}"
      cur="${cur#"${cur%%[![:space:]]*}"}"; cur="${cur%"${cur##*[![:space:]]}"}"
      printf -v "$v" '%s' "$cur" 2>/dev/null || eval "$v=\"\$cur\""
    done
    [[ -z "$name" || "${name:0:1}" == "#" ]] && continue
    issue_leaf "$name" "$slug" "$role" "$kind"
  done < "$PKI_DIR/openssl/nodes.conf"
}
