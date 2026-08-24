# harness/lib.sh — shared by the hooks and the CLI. Source it after ROOT is set.
# Needs: ROOT (absolute workspace root). Sets RULES to the merged registry.
# Env: HARNESS_RULES (generic registry), HARNESS_PROJECT_RULES (the project
# overlay; default <ROOT>/.devcontainer/rules/rules.json), HARNESS_AGENT_DIR,
# HARNESS_APPROVAL_DIR.
AGENT=${HARNESS_AGENT_DIR:-/run/harness/agent}          # agent-writable run state
APPROV=${HARNESS_APPROVAL_DIR:-/run/harness/approvals}  # root-only: operator tokens
_LIB_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
HARNESS_OFF=${HARNESS_OFF:-/run/harness/off}                 # operator's switch (dcc harness off)
harness_off() { [ -e "$HARNESS_OFF" ]; }
GENERIC_RULES=${HARNESS_RULES:-$_LIB_DIR/rules.json}
PROJECT_RULES=${HARNESS_PROJECT_RULES:-${ROOT:-.}/.devcontainer/rules/rules.json}
PROJECT_DIR=$(dirname "$PROJECT_RULES")

# load_rules: merge the project overlay over the generic registry into a temp
# file; RULES points at it and children see it as HARNESS_RULES. Fails closed:
# an unreadable generic registry or a corrupt overlay leaves RULES unset.
load_rules() {
    local merged; merged=$(mktemp) || return 1
    if [ -f "$PROJECT_RULES" ]; then
        jq -s '
          .[0] as $g | .[1] as $p | ($p.disabled // []) as $off | ($p.rules // []) as $pr |
          { steps: $g.steps, version: $g.version,
            phases: ($g.phases * ($p.phases // {})),
            project: ($p.project // {}),
            rules: ( [ $g.rules[] | select(.id as $i | ($off | index($i)) | not)
                       | . as $r | (($pr | map(select(.id == $r.id))) | first) // $r ]
                     + [ $pr[] | select(.id as $i | ($g.rules | map(.id) | index($i)) | not) ] ) }
          | .rules |= map(if .id == "protected-paths" then .check.paths += ($p.protected_paths // []) else . end)
        ' "$GENERIC_RULES" "$PROJECT_RULES" >"$merged" 2>/dev/null || { rm -f "$merged"; return 1; }
    else
        jq . "$GENERIC_RULES" >"$merged" 2>/dev/null || { rm -f "$merged"; return 1; }
    fi
    RULES=$merged; export HARNESS_RULES=$merged
    # expand now: the variable is local, and set -u would trip the trap at exit
    trap "rm -f '$merged'" EXIT
}
load_rules || RULES=

# plan_blob <workspace-relative plan path>: the committed blob hash of the
# plan, or empty when it is not committed or has uncommitted changes.
plan_blob() {
    local rel=$1 repo in_repo
    repo=$(git -C "$ROOT/$(dirname "$rel")" rev-parse --show-toplevel 2>/dev/null) || return 0
    in_repo=${ROOT%/}/$rel; in_repo=${in_repo#"$repo"/}
    [ -z "$(git -C "$repo" status --porcelain -- "$in_repo" 2>/dev/null)" ] || return 0
    git -C "$repo" rev-parse --verify -q "HEAD:$in_repo" 2>/dev/null || true
}

# token_blob <token-file> / token_scope <token-file>: the approval token is
# JSON {blob, scope[]} (older tokens: the bare blob; scope = everything)
token_blob()  { jq -r '.blob // empty' "$1" 2>/dev/null || cat "$1"; }
token_scope() { jq -r '.scope[]? // "*"' "$1" 2>/dev/null; }
approval_token() { echo "$APPROV/$(basename "${1:-none}").approved"; }

# effective_phase: the declared phase, except that `implement` holds only
# while the operator's token matches the committed plan. No state at all
# means brainstorm — the most restrictive phase (fail closed).
effective_phase() {
    local st=$AGENT/run.json p plan tok
    [ -r "$st" ] || { echo brainstorm; return; }
    p=$(jq -r '.phase // "brainstorm"' "$st" 2>/dev/null) || { echo brainstorm; return; }
    if [ "$p" = implement ]; then
        plan=$(jq -r '.plan // empty' "$st"); tok=$(approval_token "$plan")
        { [ -n "$plan" ] && [ -f "$tok" ] && [ "$(token_blob "$tok")" = "$(plan_blob "$plan")" ]; } || { echo review; return; }
    fi
    echo "$p"
}

# implement_scope: the write scope the operator attached to the approval
implement_scope() { local plan; plan=$(jq -r '.plan // empty' "$AGENT/run.json" 2>/dev/null); token_scope "$(approval_token "$plan")"; }
