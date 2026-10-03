#!/usr/bin/env bash
#
# Issues every end-entity certificate listed in openssl/nodes.conf, each signed
# by the CA of the organisation that owns it.
#
# Certificates land in network/pki/out/<org>/issued/<name>/, which is gitignored.
set -euo pipefail

PKI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PKI_DIR
source "$PKI_DIR/lib/common.sh"

if [[ ! -f "$PKI_DIR/out/root/certs/root.cert.pem" ]]; then
  echo "no root CA. run ./network/pki/gen-root.sh first"
  exit 1
fi

echo "==> issuing end-entity certificates"
for_each_node
echo
echo "done. certificates under network/pki/out/<org>/issued/"
