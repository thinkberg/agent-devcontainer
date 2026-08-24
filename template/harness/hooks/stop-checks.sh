#!/bin/bash
# harness/hooks/stop-checks.sh — Stop hook. Runs every rule with trigger
# stop and a `check.run`; a rule with `paths` only when this session wrote
# a matching file (pre-write/post-write record what was touched). enforcement "block": a violation blocks the stop
# (exit 2, once per session per rule — a ceiling so a session cannot loop);
# enforcement "warn": the finding goes into a systemMessage and the stop
# proceeds. Errors are reported like violations (fail closed).
set -uo pipefail
# operator's runtime switch: a root-owned marker, set from the host with
# `dcc harness off`; gone on every container start (fail closed = on)
[ -e "${HARNESS_OFF:-/run/harness/off}" ] && exit 0
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$HERE/../dispatch.sh"
input=$(cat); sid=$(jq -r '.session_id // "nosession"' <<<"$input")
ROOT=$(realpath -m -- "${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // "."' <<<"$input")}")
. "$HERE/../lib.sh"; . "$HERE/../dispatch.sh"
[ -n "$RULES" ] || { echo "harness [harness-registry]: rule registry unreadable or overlay corrupt" >&2; exit 2; }
state=${HARNESS_AGENT_DIR:-/run/harness/agent}; [ -d "$state" ] && [ -w "$state" ] || state=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/harness-session; mkdir -p "$state" 2>/dev/null
block=; warn=
touched=$(cat "$AGENT/$sid.touched" 2>/dev/null | sort -u)
while IFS= read -r r; do
    id=$(jq -r .id <<<"$r"); enf=$(jq -r '.enforcement // "warn"' <<<"$r")
    # a rule with `paths` binds only when this session wrote a matching file;
    # pre-existing findings are the gate's business (dcc check), not this session's
    if jq -e '.check.paths' <<<"$r" >/dev/null; then
        hit=; while IFS= read -r g; do while IFS= read -r t; do [ -n "$t" ] && [[ $t == $g ]] && hit=1; done <<<"$touched"; done < <(jq -r '.check.paths[]' <<<"$r")
        [ -n "$hit" ] || continue
    fi
    out=$(run_checker "$(jq -r .check.run <<<"$r")" "" <<<"$input"); crc=$?
    [ $crc -eq 0 ] && continue
    line="harness [$id]: $(explain $crc) — ${out//$'\n'/; }"
    marker=$state/$sid.stop-$id
    if [ "$enf" = block ] && [ ! -f "$marker" ]; then touch "$marker"; block+="$line"$'\n'; else warn+="$line"$'\n'; fi
done < <(rules_with_trigger stop | jq -c 'select(.check.run)')
if [ -n "$block" ]; then printf '%s%s' "$block" "${warn:+$warn}" >&2; echo "These concern what this session changed. Fix them before finishing, or say why you cannot (each blocks once; the gate refuses the run regardless)." >&2; exit 2; fi
[ -z "$warn" ] || jq -n --arg m "${warn%$'\n'}" '{systemMessage:$m}'
exit 0
