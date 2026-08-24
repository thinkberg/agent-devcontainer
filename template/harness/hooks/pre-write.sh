#!/bin/bash
# harness/hooks/pre-write.sh — Claude Code PreToolUse hook, matcher
# "Edit|Write|MultiEdit|NotebookEdit|Bash".
# Denies writes to the paths listed under the `protected-paths` rule, and —
# the phase gate — writes that the current phase of the working process
# does not permit (rules.json `phases`): brainstorm and plan and review
# allow markdown in the planning repo only; implement allows everything
# else, and holds only while the operator's approval token matches the
# committed plan.
# Globs are workspace-relative (bash pattern, `*` also matches `/`) or
# absolute when they start with `/`. For Bash the check is a heuristic:
# a write-ish verb in the command plus a token that resolves to a
# protected path. The guarantee is the read-only bind mount; this hook is
# the early feedback. Fails closed on an unreadable registry.
set -uo pipefail
# operator's runtime switch: a root-owned marker, set from the host with
# `dcc harness off`; gone on every container start (fail closed = on)
[ -e "${HARNESS_OFF:-/run/harness/off}" ] && exit 0

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

deny() {   # deny <path> <glob>
    jq -n --arg p "$1" --arg g "$2" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:("harness [protected-paths]: " + $p + " is read-only for the agent (matches " + $g + ")")}}'
    exit 0
}

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
root=${CLAUDE_PROJECT_DIR:-$cwd}
[ -n "$root" ] || exit 0
root=$(realpath -m -- "$root"); ROOT=$root
. "$HERE/../lib.sh"
[ -n "$RULES" ] || { jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"harness [harness-registry]: rule registry unreadable or overlay corrupt"}}'; exit 0; }
mapfile -t GLOBS < <(jq -r '.rules[] | select(.id=="protected-paths" and .class=="enforce") | .check.paths[]' "$RULES")
PHASE=
if jq -e '.rules[] | select(.id=="phase-gate" and .class=="enforce")' "$RULES" >/dev/null; then
    PHASE=$(effective_phase)
    mapfile -t ALWAYS < <(jq -r '.phases.always_allow[]?' "$RULES")
    if [ "$PHASE" = implement ]; then mapfile -t ALLOW < <(implement_scope); else mapfile -t ALLOW < <(jq -r --arg p "$PHASE" '.phases.allow_write[$p][]?' "$RULES"); fi
fi
[ ${#GLOBS[@]} -gt 0 ] || [ -n "$PHASE" ] || exit 0

deny_phase() {   # deny_phase <path>
    local next; next=$(jq -r --arg p "$PHASE" '.phases.order as $o | ($o | index($p)) as $i | if $i+1 < ($o|length) then $o[$i+1] else $p end' "$RULES")
    jq -n --arg p "$1" --arg ph "$PHASE" --arg allow "$(printf '%s ' "${ALLOW[@]}")" --arg next "$next" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:(if $ph == "implement" then "harness [scope-to-project]: the approved scope is " + $allow + "— " + $p + " is outside it; ask the operator to widen it (dcc approve <plan> --scope …)" else "harness [phase-gate]: phase " + $ph + " allows writes only to " + $allow + "— " + $p + " is outside. Next: harness phase " + $next + " (see harness status)" end)}}'
    exit 0
}

check_path() {   # check_path <path> — deny if it matches a protected glob
    local p=$1 abs rel g
    [ -n "$p" ] || return 0
    case $p in /*) abs=$(realpath -m -- "$p") ;; *) abs=$(realpath -m -- "${cwd:-$root}/$p") ;; esac
    rel=${abs#"$root"/}
    for g in "${GLOBS[@]}"; do
        case $g in
            /*) [[ $abs == $g ]] && deny "$abs" "$g" ;;
            *)  [ "$rel" != "$abs" ] && [[ $rel == $g ]] && deny "$rel" "$g" ;;
        esac
    done
    # phase gate: only for paths inside the workspace; for Bash tokens only
    # when the token is a real path (exists, or its parent does) — a sed
    # expression like s/a/b/ looks like a path and is not one
    if [ -n "$PHASE" ] && [ "$rel" != "$abs" ] && { [ "$tool" != Bash ] || [ -e "$abs" ] || [ -d "$(dirname "$abs")" ]; }; then
        for g in "${ALWAYS[@]}"; do [[ $abs == $g || $rel == $g ]] && return 0; done
        for g in "${ALLOW[@]}"; do [[ $rel == $g ]] && return 0; done
        deny_phase "$rel"
    fi
    return 0
}

# note_touched <path>: remember what this session wrote, for the Stop-time
# checks (a stop rule with `paths` binds only when the session touched one)
sid=$(jq -r '.session_id // "nosession"' <<<"$input")
note_touched() { local abs rel; case $1 in /*) abs=$(realpath -m -- "$1");; *) abs=$(realpath -m -- "${cwd:-$root}/$1");; esac
    rel=${abs#"$root"/}; [ "$rel" != "$abs" ] || return 0
    { [ -e "$abs" ] || [ -d "$(dirname "$abs")" ]; } || return 0      # not a real path (a sed expression, say)
    mkdir -p "$AGENT" 2>/dev/null && echo "$rel" >>"$AGENT/$sid.touched" 2>/dev/null || true; }

case $tool in
    Edit|Write|MultiEdit|NotebookEdit)
        f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
        check_path "$f"; note_touched "$f" ;;
    Bash)
        cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
        # Judge write TARGETS only — never every path in the command: a
        # path merely read (cat, grep, find) is not a write, and `2>/dev/null`
        # is not a redirect into the workspace. Targets are:
        #   - redirect destinations: > f, >> f, 1> f, &> f  (not 2> f, not >&1)
        #   - the file arguments of commands that write, move or delete
        targets=()
        while IFS= read -r t; do [ -n "$t" ] && targets+=("$t"); done < <(
            grep -oE '(^|[^0-9&])(&|[01])?>>?[[:space:]]*[^[:space:]&|;<>]+' <<<"$cmd" | sed -E 's/^.*>>?[[:space:]]*//')
        while IFS= read -r seg; do
            read -r -a w <<<"$seg"; [ ${#w[@]} -gt 0 ] || continue
            c=${w[0]##*/}; args=("${w[@]:1}")
            while [ "$c" = sudo ] || [ "$c" = env ] || [ "$c" = nice ] || [ "$c" = timeout ]; do   # peel wrappers
                [ ${#args[@]} -gt 0 ] || break; c=${args[0]##*/}; args=("${args[@]:1}")
                while [ ${#args[@]} -gt 0 ] && [[ ${args[0]} == -* || ${args[0]} == *=* && $c == env ]]; do args=("${args[@]:1}"); done
            done
            mode=all
            case $c in
                sed)      grep -qE '(^|[[:space:]])-[a-zA-Z]*i' <<<"$seg" || continue ;;      # only in-place
                tee|truncate|touch|chmod|chown|mkdir|rm|rmdir|mv|dd) ;;
                cp|rsync|install|ln) mode=last ;;                                          # sources are reads
                git) # one pass: skip -C/-c and their values, the first bare word is the subcommand
                     n=(); skip=; cdir=; sub=
                     for a in "${args[@]}"; do
                         [ -n "$skip" ] && { [ "$skip" = C ] && cdir=$a; skip=; continue; }
                         case $a in -C) skip=C;; -c) skip=c;; -*) ;; *) if [ -z "$sub" ]; then sub=$a; else n+=("$a"); fi;; esac
                     done
                     [ "$sub" = mv ] || [ "$sub" = rm ] || continue
                     # paths are relative to the -C directory, not the cwd
                     args=(); for a in "${n[@]}"; do [[ -n $cdir && $a != /* ]] && a=$cdir/$a; args+=("$a"); done ;;
                *) continue ;;
            esac
            files=(); for a in "${args[@]}"; do case $a in -*|'>'|'>>'|'<'|'2>&1') ;; *) files+=("$a");; esac; done
            [ ${#files[@]} -gt 0 ] || continue
            if [ "$mode" = last ]; then targets+=("${files[-1]}"); else targets+=("${files[@]}"); fi
        done < <(sed -E 's/\|\||&&|[|;]/\n/g' <<<"$cmd")
        for tok in "${targets[@]}"; do
            tok=${tok#[\"\']}; tok=${tok%[\"\']}
            case $tok in -*|"") continue;; esac
            check_path "$tok"
            note_touched "$tok"
        done
        ;;
esac
exit 0
