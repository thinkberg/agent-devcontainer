#!/bin/bash
# Temporary egress grant (root; invoked from the HOST via `dcc allow <domain>`
# — approval deliberately lives outside the container). The grant is runtime
# ipset state only: it disappears on container restart. Promote domains that
# earn their keep to allowlist.txt via PR + rebuild.
set -euo pipefail

domain="${1:?usage: cc-allow.sh <domain>}"
ips=$(dig +short A "$domain" | grep -E '^[0-9.]+$' || true)
[ -n "$ips" ] || { echo "ERROR: $domain did not resolve" >&2; exit 1; }
for ip in $ips; do
    ipset add allowed "$ip" -exist
    echo "allowed $domain -> $ip (until container restart)"
done
