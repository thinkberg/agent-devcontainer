#!/bin/bash
# Temporary egress grant (root; invoked from the HOST via `dcc allow <domain|ip>`
# — approval deliberately lives outside the container). The grant is runtime
# ipset state only: it disappears on container restart. Promote domains that
# earn their keep to allowlist.txt via PR + rebuild.
set -euo pipefail

domain="${1:?usage: cc-allow.sh <domain|ip>}"
# getent, as in the firewall: resolves a name via nsswitch and passes an IP
# literal through (dig +short A on a literal answers nothing)
ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u) || true
[ -n "$ips" ] || { echo "ERROR: $domain did not resolve" >&2; exit 1; }
for ip in $ips; do
    ipset add allowed "$ip" -exist
    echo "allowed $domain -> $ip (until container restart)"
done
# the firewall's refresh loop resolves the grants again too (a CDN host
# answers with other addresses later); a full firewall run drops the file
echo "$domain" >> /run/firewall-grants.txt
