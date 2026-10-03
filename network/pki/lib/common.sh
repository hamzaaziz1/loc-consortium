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
