#!/usr/bin/env bash
#
# Proves the privacy property: a party to a credit, holding a valid consortium
# encryption certificate, cannot read terms it is not a recipient of.
#
# This is the claim the whole design rests on, and it is stronger than it
# sounds. The logistics operator is an active consortium member, a named party
# to the credit, holds a certificate issued by its own CA under the consortium
# root, and records shipment milestones against the credit. It still cannot
# read the commercial terms.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKI="$REPO/network/pki/out"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

cat > "$WORK/terms.json" <<'JSON'
{
  "reference": "LC-TEST-0001",
  "amount": "450000.00",
  "currency": "USD",
  "goods": "12000 units cotton fabric, 180gsm, grade A",
  "beneficiary": "Pacific Textiles Co"
}
JSON

CANON="$WORK/canon.json"
jq -Sc '.' "$WORK/terms.json" > "$CANON"
COMMITMENT="$(cast keccak "$(cat "$CANON")")"

echo "0. the fixtures exist"
for slug in importer-bank exporter-bank logistics; do
  [[ -f "$PKI/$slug/issued/terms/terms.cert.pem" ]] || {
    bad "no encryption certificate for $slug; run gen-leaves.sh"
    echo; echo "$pass passed, $fail failed"; exit 1
  }
done
ok "encryption certificates present for all three organisations"

echo "1. terms seal to the two banks only"
openssl cms -encrypt -binary -aes-256-gcm \
  -in "$CANON" -out "$WORK/sealed.cms" -outform DER \
  "$PKI/importer-bank/issued/terms/terms.cert.pem" \
  "$PKI/exporter-bank/issued/terms/terms.cert.pem" 2>/dev/null \
  && ok "sealed to importer and exporter banks" \
  || bad "sealing failed"

echo "2. each bank recovers the exact bytes"
for slug in importer-bank exporter-bank; do
  out="$(openssl cms -decrypt -binary -inform DER -in "$WORK/sealed.cms" \
        -recip "$PKI/$slug/issued/terms/terms.cert.pem" \
        -inkey "$PKI/$slug/issued/terms/terms.key.pem" 2>/dev/null)"
  if [[ "$(cast keccak "$out")" == "$COMMITMENT" ]]; then
    ok "$slug recovered terms matching the commitment"
  else
    bad "$slug did not recover the exact bytes"
  fi
done

echo "3. the logistics operator cannot read the terms"
# A member, a party to the credit, with a valid certificate from the same root.
if openssl cms -decrypt -binary -inform DER -in "$WORK/sealed.cms" \
     -recip "$PKI/logistics/issued/terms/terms.cert.pem" \
     -inkey "$PKI/logistics/issued/terms/terms.key.pem" >/dev/null 2>&1; then
  bad "the logistics operator decrypted terms it is not a recipient of"
else
  ok "logistics refused: not a recipient"
fi

echo "4. a member cannot read by substituting another member's certificate"
# Holding someone else's certificate is not holding their private key. This
# distinguishes "not a recipient" from "could impersonate a recipient".
if openssl cms -decrypt -binary -inform DER -in "$WORK/sealed.cms" \
     -recip "$PKI/importer-bank/issued/terms/terms.cert.pem" \
     -inkey "$PKI/logistics/issued/terms/terms.key.pem" >/dev/null 2>&1; then
  bad "a mismatched certificate and key decrypted the terms"
else
  ok "the importer bank's certificate is useless without its key"
fi

echo "5. the commitment is over the plaintext, not the ciphertext"
# CMS encryption is randomised, so the same terms seal to different bytes each
# time. A commitment over ciphertext could not prove two parties hold the same
# terms.
openssl cms -encrypt -binary -aes-256-gcm -in "$CANON" -out "$WORK/again.cms" -outform DER \
  "$PKI/importer-bank/issued/terms/terms.cert.pem" \
  "$PKI/exporter-bank/issued/terms/terms.cert.pem" 2>/dev/null
if cmp -s "$WORK/sealed.cms" "$WORK/again.cms"; then
  bad "two seals of the same terms produced identical ciphertext"
else
  ok "ciphertext differs between seals, the commitment does not"
fi

echo "6. tampered terms fail verification"
jq -Sc '.amount = "4500.00"' "$CANON" > "$WORK/tampered.json"
if [[ "$(cast keccak "$(cat "$WORK/tampered.json")")" == "$COMMITMENT" ]]; then
  bad "altered terms produced the same commitment"
else
  ok "altering the amount changes the commitment"
fi

echo "7. canonical form is stable across key order and whitespace"
# The property that makes the commitment reproducible between parties who
# wrote the same terms differently.
printf '{\n  "currency" : "USD",\n  "amount":"450000.00",\n  "reference":"LC-TEST-0001",\n  "goods":"12000 units cotton fabric, 180gsm, grade A",\n  "beneficiary":"Pacific Textiles Co"\n}\n' > "$WORK/reordered.json"
if [[ "$(cast keccak "$(jq -Sc '.' "$WORK/reordered.json")")" == "$COMMITMENT" ]]; then
  ok "reordered, reformatted terms commit identically"
else
  bad "canonicalisation is not stable"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
