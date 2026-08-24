#!/bin/bash
# harness/hooks/pre-bash.sh — Claude Code PreToolUse hook, matcher "Bash".
# Reads the rule registry and denies the command when an `enforce` rule
# with trigger "pre_bash" matches. First match wins; the rule id is in the
# reason so the agent (and the log) can name the rule that fired.
#
# Contract: JSON on stdin, JSON decision on stdout, exit 0. No output = no
# decision (the normal permission flow applies). Fails closed: an
# unreadable registry denies every command.
#
# This is the inner loop (step 4 in docs/safety-harness.md). It gives fast
# feedback; it is not the security boundary. Regexes are line-based and
# not quote-aware — a flag inside a commit message can trip a rule. That
# is the accepted trade: a false deny costs one retry, a false allow costs
# an incident.
set -uo pipefail
# operator's runtime switch: a root-owned marker, set from the host with
# `dcc harness off`; gone on every container start (fail closed = on)
[ -e "${HARNESS_OFF:-/run/harness/off}" ] && exit 0

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

deny() {   # deny <rule-id> <reason>
    jq -n --arg id "$1" --arg why "$2" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:("harness [" + $id + "]: " + $why)}}'
    exit 0
}

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || cmd=
[ -n "$cmd" ] || exit 0
ROOT=$(realpath -m -- "${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // "."' <<<"$input")}")
. "$HERE/../lib.sh"; . "$HERE/../dispatch.sh"
[ -n "$RULES" ] || deny harness-registry "rule registry unreadable or overlay corrupt (generic: ${HARNESS_RULES:-default}, project: $PROJECT_RULES)"

rule_active() { jq -e --arg id "$1" '.rules[] | select(.id==$id and .class=="enforce")' "$RULES" >/dev/null; }

# ---- builtin: git-c-absolute ------------------------------------------------
# Every occurrence of a mutating git subcommand must carry -C /absolute/path.
# A relative -C is refused too: the incident was a cd that did not persist.
MUT='add|commit|push|mv|rm|reset|rebase|merge|checkout|switch|tag|stash|cherry-pick|revert|restore|clean|am|apply'
if rule_active git-c-absolute; then
    while IFS= read -r occ; do
        [ -n "$occ" ] || continue
        grep -qE '\s-C\s+/' <<<"$occ" || deny git-c-absolute \
            "mutating git without -C /absolute/path in '$occ' — name the repo explicitly, a cd does not persist between calls"
    done < <(grep -oE "\bgit(\s+-[cC]\s+\S+)*\s+(${MUT})\b" <<<"$cmd" || true)
fi

# ---- checker-backed rules: `when` selects the command, the checker decides ---
while IFS= read -r r; do
    when=$(jq -r .check.when <<<"$r"); grep -qE -- "$when" <<<"$cmd" || continue
    out=$(run_checker "$(jq -r .check.run <<<"$r")" "" <<<"$input"); crc=$?
    [ $crc -eq 0 ] || deny "$(jq -r .id <<<"$r")" "$(explain $crc): ${out//$'\n'/; } — $(jq -r .text <<<"$r")"
done < <(rules_with_trigger pre_bash | jq -c 'select(.check.run and .check.when)')

# ---- data-driven regex rules ------------------------------------------------
mapfile -t RX < <(rules_with_trigger pre_bash | jq -c 'select(.check.regex)')
for r in "${RX[@]}"; do
    id=$(jq -r .id <<<"$r")
    when=$(jq -r '.check.when // empty' <<<"$r")
    flags=-E; [ "$(jq -r '.check.icase // false' <<<"$r")" = true ] && flags=-iE
    if [ -n "$when" ]; then grep -qE -- "$when" <<<"$cmd" || continue; fi
    while IFS= read -r re; do
        [ -n "$re" ] || continue
        grep -q $flags -- "$re" <<<"$cmd" && deny "$id" "$(jq -r .text <<<"$r")"
    done < <(jq -r '.check.regex | if type=="array" then .[] else . end' <<<"$r")
done
exit 0
