#!/bin/bash
# harness/hooks/post-write.sh — PostToolUse hook, matcher "Edit|Write|MultiEdit|NotebookEdit".
# For every rule with trigger post_write whose `check.paths` matches the
# edited file, runs `check.run` (placeholders: {checkers} {root} {file}
# {repo}). A violation or an error goes back to the agent on stderr with
# exit 2 — the edit has already happened, so this is feedback, not a
# block. Errors are reported as failures (fail closed).
set -uo pipefail
# operator's runtime switch: a root-owned marker, set from the host with
# `dcc harness off`; gone on every container start (fail closed = on)
[ -e "${HARNESS_OFF:-/run/harness/off}" ] && exit 0
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
input=$(cat)
f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input"); [ -n "$f" ] || exit 0
root=$(realpath -m -- "${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // "."' <<<"$input")}"); ROOT=$root
. "$HERE/../lib.sh"; . "$HERE/../dispatch.sh"
[ -n "$RULES" ] || { echo "harness [harness-registry]: rule registry unreadable or overlay corrupt" >&2; exit 2; }
abs=$(realpath -m -- "$f"); rel=${abs#"$root"/}; [ "$rel" != "$abs" ] || exit 0
sid=$(jq -r '.session_id // "nosession"' <<<"$input"); mkdir -p "$AGENT" 2>/dev/null && echo "$rel" >>"$AGENT/$sid.touched" 2>/dev/null || true
rc=0; msgs=
while IFS= read -r r; do
    hit=; while IFS= read -r g; do [[ $rel == $g ]] && hit=1; done < <(jq -r '.check.paths[]' <<<"$r"); [ -n "$hit" ] || continue
    out=$(run_checker "$(jq -r .check.run <<<"$r")" "$rel" <<<"$input"); crc=$?
    [ $crc -eq 0 ] && continue
    msgs+="harness [$(jq -r .id <<<"$r")]: $(explain $crc)"$'\n'"$out"$'\n'; rc=2
done < <(rules_with_trigger post_write | jq -c 'select(.check.run and .check.paths)')
[ $rc -eq 0 ] || printf '%s' "$msgs" >&2
exit $rc
