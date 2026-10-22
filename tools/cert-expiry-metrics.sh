#!/usr/bin/env bash
#
# Writes certificate expiry as Prometheus metrics.
#
# ADR 0004 named this: eleven certificates rotate annually by hand, and the
# failure mode is the network stopping with no warning beyond expiry dates
# nobody is watching. When a node certificate expires its RPC endpoint stops
# accepting clients, and Besu logs nothing when it rejects every client
# (ADR 0005), so the outage has no symptom in the logs.
#
# A textfile rather than an exporter, deliberately. Reading expiry needs
# filesystem access to the PKI, and mounting the private CA into a long-running
# network service to read dates would be the wrong trade. This runs on a timer,
# touches no keys, and writes one file.
#
# Usage:  bash tools/cert-expiry-metrics.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI="$REPO/network/pki/out"
OUT="${CERT_METRICS_FILE:-$REPO/observability/textfile/certificates.prom}"

[[ -d "$PKI" ]] || { echo "no PKI at $PKI"; exit 1; }
mkdir -p "$(dirname "$OUT")"

now="$(date +%s)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo "# HELP consortium_certificate_expiry_days Days until a certificate expires."
  echo "# TYPE consortium_certificate_expiry_days gauge"
} > "$tmp"

emit() {
  local file="$1" kind="$2" org="$3"
  local subject end end_epoch days
  subject="$(openssl x509 -in "$file" -noout -subject 2>/dev/null | sed 's/^subject=//')" || return 0
  end="$(openssl x509 -in "$file" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 0
  end_epoch="$(date -d "$end" +%s 2>/dev/null)" || return 0
  days=$(( (end_epoch - now) / 86400 ))
  local cn
  cn="$(echo "$subject" | sed 's/.*CN *= *//; s/,.*//')"
  printf 'consortium_certificate_expiry_days{certificate="%s",kind="%s",org="%s"} %d\n' \
    "$cn" "$kind" "$org" "$days" >> "$tmp"
}

# The root. Ten years, so it will not alert, and it is here because a root
# quietly approaching expiry is the worst version of this problem: every
# certificate beneath it becomes unverifiable at once.
emit "$PKI/root/certs/root.cert.pem" root consortium

for dir in "$PKI"/*/; do
  org="$(basename "$dir")"
  [[ "$org" == "root" || "$org" == "keystores" ]] && continue
  [[ -f "$dir/certs/$org.cert.pem" ]] && emit "$dir/certs/$org.cert.pem" intermediate "$org"
  for issued in "$dir"issued/*/; do
    [[ -d "$issued" ]] || continue
    name="$(basename "$issued")"
    [[ -f "$issued/$name.cert.pem" ]] && emit "$issued/$name.cert.pem" leaf "$org"
  done
done

{
  echo ""
  echo "# HELP consortium_certificate_metrics_timestamp_seconds When these metrics were written."
  echo "# TYPE consortium_certificate_metrics_timestamp_seconds gauge"
  echo "consortium_certificate_metrics_timestamp_seconds $now"
  echo ""
  echo "# HELP consortium_certificates_total Certificates found in the PKI."
  echo "# TYPE consortium_certificates_total gauge"
  echo "consortium_certificates_total $(grep -c '^consortium_certificate_expiry_days{' "$tmp" || echo 0)"
} >> "$tmp"

# World readable: the static file server runs as its own user and cannot read
# an owner-only file. mktemp creates at 0600 and mv preserves it, so without
# this the scrape fails with 403 while the file looks perfectly fine on disk.
# These are expiry dates, not secrets.
chmod 644 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT

echo "wrote $OUT"
grep -c '^consortium_certificate_expiry_days{' "$OUT" | xargs printf '  %s certificates\n'
sort -t' ' -k2 -n "$OUT" | grep '^consortium_certificate_expiry_days{' | head -3 | sed 's/^/  soonest: /'
