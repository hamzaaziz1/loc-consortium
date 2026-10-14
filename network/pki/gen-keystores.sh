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
#
# THE TRUSTSTORE IS BUILT WITH keytool, NOT openssl, AND THAT MATTERS.
#
# A certificate in a Java truststore has to be marked as a trusted certificate
# entry, which is a Java-specific attribute inside the PKCS12 bag that
# `openssl pkcs12 -export -nokeys` does not write. The resulting file is a
# structurally valid PKCS12 that Java loads without complaint and then treats
# as containing zero trust anchors.
#
# Nothing reports this. The node starts cleanly, the TLS listener comes up, and
# every mutual TLS handshake then fails with the server requesting a client
# certificate while advertising no acceptable CAs. The diagnostic that finds it
# is `openssl s_client`, whose "acceptable client certificate CA names" line
# shows what the server actually trusts rather than what you believe you gave
# it.
#
# keytool comes from the pinned Besu image rather than a separate JDK, so the
# tool writing the truststore is the same JDK that will read it. Given the bug
# above was precisely a writer/reader mismatch, that is worth the coupling.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_DIR
source "$PKI_DIR/lib/common.sh"

BESU_IMAGE="${BESU_IMAGE:-hyperledger/besu:26.8.1}"

# The truststore step needs keytool, which comes from the Besu image, so this
# script now requires docker where the earlier PKI scripts did not.
command -v docker >/dev/null || {
  echo "docker is required to build the truststore (keytool comes from the Besu image)"
  exit 1
}

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

echo "==> truststore (root only, built with keytool)"
# keytool refuses to overwrite, and rm -rf above has already cleared the
# directory, so there is nothing to remove here.
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$OUT:/pki" \
  --entrypoint keytool "$BESU_IMAGE" \
  -importcert -noprompt \
  -alias loc-consortium-root \
  -file /pki/root/certs/root.cert.pem \
  -keystore /pki/keystores/truststore.p12 \
  -storetype PKCS12 \
  -storepass "$PW" >/dev/null
chmod 444 "$STORE_DIR/truststore.p12"
echo "    truststore.p12"

# Assert the anchor is actually there. The failure this guards against is
# silent, so the check is not optional.
anchors="$(docker run --rm --user "$(id -u):$(id -g)" \
  -v "$OUT:/pki" --entrypoint keytool "$BESU_IMAGE" \
  -list -keystore /pki/keystores/truststore.p12 \
  -storetype PKCS12 -storepass "$PW" 2>/dev/null \
  | grep -c trustedCertEntry || true)"
if [[ "$anchors" -lt 1 ]]; then
  echo
  echo "truststore contains no trusted certificate entries."
  echo "every mutual TLS handshake would fail with no error logged anywhere."
  exit 1
fi
echo "    $anchors trusted certificate entry present"

echo
echo "keystores in $STORE_DIR"
