# harness/dispatch.sh — shared by the dispatching hooks and `harness check`.
# Needs: RULES, ROOT, PROJECT_DIR (from lib.sh).
CHECKERS=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/checkers

# rules_with_trigger <name>: the rules whose trigger (string or array) includes <name>, as compact JSON lines
rules_with_trigger() {
    jq -c --arg t "$1" '.rules[] | select(.class != "advise") | select((.trigger // empty | if type=="array" then . else [.] end) | index($t))' "$RULES"
}
# run_checker <run-template> <rel-file>: substitutes placeholders and runs; stdin passes through
run_checker() {
    local cmd=$1 rel=${2:-} repo; repo=${rel%%/*}
    cmd=${cmd//\{checkers\}/$CHECKERS}; cmd=${cmd//\{project\}/$PROJECT_DIR}; cmd=${cmd//\{root\}/$ROOT}; cmd=${cmd//\{file\}/$rel}; cmd=${cmd//\{repo\}/$repo}
    timeout "${HARNESS_CHECK_TIMEOUT:-60}" bash -c "$cmd"; local rc=$?
    [ $rc -eq 124 ] && { echo "checker timed out"; return 3; }
    return $rc
}
explain() { case $1 in 1) echo "violation";; 2) echo "approval needed";; *) echo "check could not run (exit $1) — treated as a failure";; esac; }
