#!/bin/bash
# Egress firewall for the agent devcontainer: outbound traffic is denied
# unless the destination is in the "allowed" ipset. This script fills that
# set from /etc/devcontainer-allowlist.txt (one domain per line, baked into
# the image — changing it means a rebuild, deliberately a host-side act)
# plus GitHub's published service ranges, then locks the iptables policies
# down. cc-allow.sh appends to the same set at runtime for temporary
# grants; every re-run rebuilds the set, so those grants vanish.
#
# Runs as root from pid 1 (entry.sh) on every container start and via
# `dcc fw`; a non-zero exit stops the container (fail closed).
#
# Independent implementation for this template (MIT). The allowlist-only
# egress idea for agent containers follows Anthropic's Claude Code
# reference devcontainer; deliberately NOT named init-firewall.sh — some
# versions of the claude-code feature install a script at that path.
set -euo pipefail

LIST=/etc/devcontainer-allowlist.txt
SET=allowed
STAGE=allowed-stage

note() { echo "firewall: $*" >&2; }
fail() { note "FAIL: $*"; exit 1; }

# ---- collect destinations into a staging set, swap atomically ------------
# Resolution happens BEFORE any rule change: on a re-run the previous
# ruleset still permits DNS and HTTPS, so we never cut the branch we sit
# on, and the live set is replaced in one step (no window with an empty
# allowlist).
ipset create "$SET"   hash:net -exist
ipset create "$STAGE" hash:net -exist
ipset flush  "$STAGE"

# GitHub publishes its git/api/web CIDRs — steadier than resolving single
# A records behind a rotating CDN (v4 only; v6 is rejected wholesale below)
if meta=$(curl -fsSL --max-time 15 https://api.github.com/meta 2>/dev/null); then
    jq -r '(.git + .api + .web)[] | select(contains(":") | not)' <<<"$meta" \
        | while read -r cidr; do ipset add "$STAGE" "$cidr" -exist; done \
        || note "GitHub meta ranges unusable, continuing with the domain list"
else
    note "GitHub meta ranges unavailable, continuing with the domain list"
fi

probe=
while read -r domain _; do
    domain=${domain%%#*}
    [ -n "$domain" ] || continue
    addrs=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u) || :
    [ -n "$addrs" ] || { note "cannot resolve $domain"; continue; }
    for a in $addrs; do ipset add "$STAGE" "$a" -exist; done
    probe=${probe:-$domain}   # first resolvable domain doubles as the probe
done < "$LIST"

entries=$(ipset save "$STAGE" | grep -c '^add ') || :
[ "$entries" -gt 0 ] || fail "nothing resolved — refusing to raise an all-blocking firewall silently"

ipset swap "$STAGE" "$SET"
ipset destroy "$STAGE"

# ---- rules: default-DROP both ways, answers and DNS excepted -------------
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
# the sidecar bridge (set via devcontainer.json, mirrors SUBNET in dcc.conf)
[ -z "${DEVCONTAINER_SUBNET:-}" ] || iptables -A OUTPUT -d "$DEVCONTAINER_SUBNET" -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set "$SET" dst -j ACCEPT
iptables -P OUTPUT DROP

iptables -F INPUT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -P INPUT DROP

# no v6 allowlist at all; REJECT (not DROP) so dual-stack clients fail
# over to v4 without waiting for timeouts
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -j REJECT 2>/dev/null || true
fi

# ---- prove the boundary before handing over ------------------------------
# positive: the first allowlisted domain must accept a connection (a TLS
# certificate mismatch, curl 60, still proves the packet path works);
# negative: 1.1.1.1 is the canary — never put it on the allowlist.
if [ -n "$probe" ]; then
    rc=0; curl -s --max-time 10 -o /dev/null "https://$probe/" || rc=$?
    case $rc in
        0|60) note "verified: $probe reachable" ;;
        *)    fail "allowlisted $probe unreachable (curl exit $rc)" ;;
    esac
fi
rc=0; curl -s --max-time 4 -o /dev/null http://1.1.1.1/ || rc=$?
[ "$rc" -ne 0 ] || fail "canary 1.1.1.1 is reachable — egress is open"
note "up: $entries nets allowed, canary blocked"
