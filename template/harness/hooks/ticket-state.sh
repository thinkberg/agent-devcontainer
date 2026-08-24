#!/bin/bash
# harness/hooks/ticket-state.sh — a completion rule with state.
#   post  : PostToolUse hook, matcher "Bash". A ticket-mutating command
#           marks the session dirty; a clean bin/check-tickets run clears it.
#   stop  : Stop hook. A dirty session may not end: exit 2 sends the
#           reason back to the agent, which must run bin/check-tickets.
# Rule: check-tickets-after-change (TICKETS.md). State lives outside the
# agent's write scope when the container provides /run/harness/agent (created by
# entry.sh as root); the fallback is only for host-side tests.
# The block has a ceiling (max_blocks) so a session cannot loop forever;
# past it the hook lets the stop through with a loud message — the gate
# is authoritative, this is the inner loop.
set -uo pipefail
# operator's runtime switch: a root-owned marker, set from the host with
# `dcc harness off`; gone on every container start (fail closed = on)
[ -e "${HARNESS_OFF:-/run/harness/off}" ] && exit 0

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
mode=${1:?usage: ticket-state.sh post|stop}

input=$(cat)
sid=$(jq -r '.session_id // "nosession"' <<<"$input")
ROOT=$(realpath -m -- "${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // "."' <<<"$input")}")
. "$HERE/../lib.sh"; [ -n "$RULES" ] || exit 0
r=$(jq -c '.rules[] | select(.id=="check-tickets-after-change")' "$RULES" 2>/dev/null) || exit 0
[ -n "$r" ] || exit 0
dirty_on=$(jq -r .check.dirty_on <<<"$r"); clean_on=$(jq -r .check.clean_on <<<"$r")
max=$(jq -r '.check.max_blocks // 3' <<<"$r")

state=${HARNESS_AGENT_DIR:-/run/harness/agent}
[ -d "$state" ] && [ -w "$state" ] || state=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/harness-session
mkdir -p "$state" || exit 0
dirty=$state/$sid.ticket-dirty; blocks=$state/$sid.ticket-blocks

case $mode in
    post)
        cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
        [ "$(jq -r '.tool_name // empty' <<<"$input")" = Bash ] || exit 0
        if grep -qE -- "$clean_on" <<<"$cmd"; then
            # PostToolUse fires on success only; a failing check-tickets lands in PostToolUseFailure
            rm -f "$dirty" "$blocks"
        elif grep -qE -- "$dirty_on" <<<"$cmd"; then
            date -u +%FT%TZ >"$dirty"
        fi
        ;;
    stop)
        [ -f "$dirty" ] || exit 0
        n=$(( $(cat "$blocks" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$blocks"
        if [ "$n" -le "$max" ]; then
            echo "harness [check-tickets-after-change]: tickets changed in this session (since $(cat "$dirty")) and bin/check-tickets has not run clean since. Run extracarts-planning/bin/check-tickets, fix or flag its findings, then finish. ($n/$max)" >&2
            exit 2
        fi
        jq -n --arg n "$n" '{systemMessage:("harness [check-tickets-after-change]: stop allowed after " + $n + " blocks — bin/check-tickets still has not run clean; the gate will refuse this run")}'
        ;;
esac
exit 0
