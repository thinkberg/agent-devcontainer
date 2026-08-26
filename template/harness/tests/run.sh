#!/bin/bash
# harness/tests/run.sh — positive / negative / bypass / fail-closed tests for
# the worked hooks. Runs on the host, needs bash + jq. Exit 1 on any failure.
# Every negative case below is a rule violation that happened (see the
# `source` field in rules.json) or a bypass of the same effect by another
# route. Keep adding cases: a violation seen in production becomes a test.
set -uo pipefail
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
H=$HERE/../harness.py
export HARNESS_RULES=$HERE/../rules.json HARNESS_PROJECT_RULES=$HERE/fixtures/project.json
WS=$(mktemp -d -p "${HOME:-/var/tmp}/.cache")     # a made-up workspace root; paths need not exist
export CLAUDE_PROJECT_DIR=$WS
export HARNESS_AGENT_DIR=$(mktemp -d)
# no global git config in tests: Leo's gpg signing would prompt; identity from env
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
trap 'rm -rf "$HARNESS_AGENT_DIR" "$WS" "${T:-}"' EXIT
pass=0; fail=0

bash_json() { jq -n --arg c "$1" --arg cwd "${2:-$WS}" '{session_id:"t1",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'; }
edit_json() { jq -n --arg f "$1" --arg cwd "$WS" '{session_id:"t1",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$f,content:"x"}}'; }
patch_json() { jq -n --arg c "$1" --arg cwd "${2:-$WS}" '{session_id:"t1",tool_name:"apply_patch",cwd:$cwd,tool_input:{command:$c}}'; }

# expect <deny:rule-id | allow> <hook> <json> <label>
expect() {
    local want=$1 hook=$2 json=$3 label=$4 out decision id
    out=$("$hook" <<<"$json" 2>/dev/null)
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"${out:-null}" 2>/dev/null)
    id=$(sed -nE 's/.*harness \[([^]]+)\].*/\1/p' <<<"$out")
    if [ "$want" = allow ] && [ "$decision" = allow ]; then pass=$((pass+1))
    elif [ "$want" = "deny:$id" ] && [ "$decision" = deny ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL [$label] wanted $want, got $decision${id:+ ($id)}"; fi
}
# expect_exit <code> <cmd...> — for the Stop hook
expect_exit() { local want=$1 label=$2; shift 2; local got; "$@" >/dev/null 2>&1; got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [$label] wanted exit $want, got $got"; fi; }

pb() { "$H" hook pre-bash "$@"; }; pw() { "$H" hook pre-write "$@"; }; ts() { "$H" hook ticket-state "$@"; }; PB=pb; PW=pw; TS=ts
P=$WS/planning

echo "== git-stage-explicit (incident 2026-07-22)"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add -A && git -C $P commit -m x")" "add -A"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add --all")" "add --all"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add .")" "add ."
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add -u")" "add -u (bypass: stages every tracked change)"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P commit -am 'x'")" "commit -am"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P commit --all -m x")" "commit --all"
expect allow "$PB" "$(bash_json "git -C $P add DONE.md plans/x.md")" "positive: add explicit paths"
expect allow "$PB" "$(bash_json "git -C $P commit -m 'x' --amend")" "positive: --amend is not -a"
expect allow "$PB" "$(bash_json "git -C $P add ./plans/x.md")" "positive: ./path is not ."

echo "== git-c-absolute (incident 2026-07-17)"
expect deny:git-c-absolute "$PB" "$(bash_json "cd planning && git commit -m x")" "the incident: cd + bare git"
expect deny:git-c-absolute "$PB" "$(bash_json "git commit -m x")" "bare commit"
expect deny:git-c-absolute "$PB" "$(bash_json "git -C ../planning push")" "bypass: relative -C"
expect deny:git-c-absolute "$PB" "$(bash_json "git -c commit.gpgsign=true commit -m x")" "bypass: -c option but no -C"
expect allow "$PB" "$(bash_json "git status --short && git log --oneline -3")" "positive: read-only git needs no -C"
expect allow "$PB" "$(bash_json "git -C $P push")" "positive: -C absolute"
expect allow "$PB" "$(bash_json "git -c core.pager=cat -C $P commit -m x")" "positive: -c then -C"

echo "== git-no-bypass"
expect deny:git-no-bypass "$PB" "$(bash_json "git -C $P commit --no-verify -m x")" "--no-verify"
expect deny:git-no-bypass "$PB" "$(bash_json "git -C $P commit -n -m x")" "-n"
expect deny:git-no-bypass "$PB" "$(bash_json "git -C $P -c core.hooksPath=/dev/null commit -m x")" "bypass: hooksPath override"
expect deny:git-no-bypass "$PB" "$(bash_json "git -C $P commit --no-gpg-sign -m x")" "--no-gpg-sign"
expect deny:git-no-bypass "$PB" "$(bash_json "git -C $P config commit.gpgsign=false")" "bypass: config gpgsign off"

echo "== no-production-push"
expect deny:no-production-push "$PB" "$(bash_json "git -C $WS/backend push origin production")" "push production"
expect deny:no-production-push "$PB" "$(bash_json "git -C $WS/backend push origin main:production")" "bypass: refspec"
expect deny:no-production-push "$PB" "$(bash_json "git -C $WS/backend push -f origin HEAD:refs/heads/production")" "bypass: full ref"
expect allow "$PB" "$(bash_json "git -C $WS/backend push -u origin task/x")" "positive: push a task branch"

echo "== git-remote-stable"
expect deny:git-remote-stable "$PB" "$(bash_json "git -C $P remote set-url origin https://github.com/x/y")" "set-url"
expect deny:git-remote-stable "$PB" "$(bash_json "git -C $P push https://token@github.com/x/y main")" "bypass: push to URL"
expect deny:git-remote-stable "$PB" "$(bash_json "git -C $P -c credential.helper=store push")" "bypass: credential helper"

echo "== no-session-links (incident 2026-08-22)"
expect deny:no-session-links "$PB" "$(bash_json "gh pr create --title x --body 'see https://claude.ai/code/session_01ABCDEFGHIJKLMNOPQRSTUV'")" "PR body"
expect deny:no-session-links "$PB" "$(bash_json "git -C $P commit -m 'x' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'")" "trailer"
expect deny:no-session-links "$PB" "$(bash_json "gh api repos/x/y/issues/5/comments -f body='Generated with [Claude Code]'")" "issue comment"
expect deny:no-session-links "$PB" "$(bash_json "git -C $P commit -F - <<'EOF'
fix
Claude-Session: https://claude.ai/code/session_01ABCDEFGHIJKLMNOPQRSTUV
EOF")" "bypass: heredoc message"
expect allow "$PB" "$(bash_json "grep -rn 'claude.ai/code/' . | head")" "positive: searching for links is not publishing them"
expect allow "$PB" "$(bash_json "gh pr create --title x --body 'plan: https://github.com/acme/planning/blob/abc123/plans/x.md'")" "positive: commit permalink"

echo "== tickets-via-bin"
expect deny:tickets-via-bin "$PB" "$(bash_json "gh issue create --repo acme/backend --title x")" "gh issue create"
expect deny:tickets-via-bin "$PB" "$(bash_json "gh issue close 12")" "gh issue close"
expect deny:tickets-via-bin "$PB" "$(bash_json "gh project item-edit --id X --field-id Y --single-select-option-id Z")" "gh project item-edit"
expect deny:tickets-via-bin "$PB" "$(bash_json "gh api repos/acme/backend/issues -f title=x")" "bypass: gh api POST issue"
expect deny:tickets-via-bin "$PB" "$(bash_json "gh api -X PATCH repos/acme/backend/issues/12 -f state=closed")" "bypass: gh api PATCH issue"
expect allow "$PB" "$(bash_json "$P/bin/add-ticket --title x --estimate 1 --repo backend")" "positive: bin/add-ticket"
expect allow "$PB" "$(bash_json "gh issue comment 12 --body 'x'")" "positive: comments are allowed"
expect allow "$PB" "$(bash_json "gh issue edit 12 --body-file /tmp/b.md")" "positive: body edits are allowed"
expect allow "$PB" "$(bash_json "gh api repos/acme/backend/issues/48/sub_issues -F sub_issue_id=123")" "positive: sub_issues API (TICKETS.md)"
expect allow "$PB" "$(bash_json "gh api repos/acme/backend/issues/12/dependencies/blocked_by -F issue_id=1")" "positive: blocked_by API (TICKETS.md)"
expect allow "$PB" "$(bash_json "gh api repos/acme/backend/issues/12 --jq .id")" "positive: read an issue"

echo "== secrets-operator-only (incidents 2026-07-24, deploy#12)"
expect deny:secrets-operator-only "$PB" "$(bash_json "gh secret set PORTAINER_API_KEY --body x")" "gh secret set"
expect deny:secrets-operator-only "$PB" "$(bash_json "sops private.sops.yml")" "sops"
expect deny:secrets-operator-only "$PB" "$(bash_json "age -d -i key.txt secrets.age")" "age decrypt"
expect deny:secrets-operator-only "$PB" "$(bash_json "psql \"\$DATABASE_URL\" -c \"alter role app with password 'x'\"")" "bypass: SQL password, lowercase"
expect allow "$PB" "$(bash_json "grep -n sops deployment/README.md")" "positive: the word in a grep"
expect allow "$PB" "$(bash_json "git -C $P commit -m 'note the average age of tickets'")" "positive: 'age' as a word"

echo "== db-no-improvise (incident 2026-08-22)"
expect deny:db-no-improvise "$PB" "$(bash_json "initdb -D /tmp/pg && pg_ctl -D /tmp/pg start")" "the incident"
expect deny:db-no-improvise "$PB" "$(bash_json ".venv/bin/pip install pgserver")" "pgserver"
expect allow "$PB" "$(bash_json "pg_isready -h postgres")" "positive: probing the sidecar is fine"

echo "== protected-paths (in isolation: registry without the phase gate)"
NOPHASE=$(mktemp); jq 'del(.rules[] | select(.id=="phase-gate"))' "$HARNESS_RULES" >"$NOPHASE"; SAVED_RULES=$HARNESS_RULES; export HARNESS_RULES=$NOPHASE
expect deny:protected-paths "$PW" "$(edit_json "$WS/www/static/legal/avv-de-v1.2.pdf")" "legal pdf"
expect deny:protected-paths "$PW" "$(edit_json "$WS/www/content/de/agb-v1-3.md")" "legal archive"
expect deny:protected-paths "$PW" "$(edit_json "$WS/www/public/index.html")" "public/"
expect deny:protected-paths "$PW" "$(edit_json "$WS/out/preview.mbox")" "root out/"
expect deny:protected-paths "$PW" "$(edit_json "$WS/backend/.github/workflows/ci.yml")" "workflow"
expect deny:protected-paths "$PW" "$(edit_json "$WS/.claude-devcontainer/settings.json")" "own settings"
expect deny:protected-paths "$PW" "$(edit_json "/home/vscode/.claude/settings.json")" "own settings, container path"
expect deny:protected-paths "$PW" "$(edit_json "$WS/planning/.devcontainer/allowlist.txt")" "policy file"
expect deny:protected-paths "$PW" "$(patch_json '*** Begin Patch
*** Update File: www/static/legal/avv-de-v1.2.pdf
*** End Patch')" "Codex apply_patch"
expect deny:protected-paths "$PW" "$(patch_json '*** Begin Patch
*** Update File: www/content/de/agb.md
*** Move to: www/static/legal/agb-v1.3.pdf
*** End Patch')" "Codex apply_patch move target"
expect deny:protected-paths "$PW" "$(bash_json "sed -i 's/a/b/' www/static/legal/avv-de-v1.2.pdf")" "bypass: sed -i"
expect deny:protected-paths "$PW" "$(bash_json "echo x > $WS/out/y.txt")" "bypass: redirect"
expect deny:protected-paths "$PW" "$(bash_json "cp a.md content/de/agb-v1-0.md" "$WS/www")" "bypass: cp, relative to cwd"
expect deny:protected-paths "$PW" "$(bash_json "git -C $WS/www rm static/legal/dpa-en-v1.0.pdf" "$WS/www")" "bypass: git rm"
expect allow "$PW" "$(edit_json "$WS/www/content/de/agb.md")" "positive: the living legal page"
expect allow "$PW" "$(edit_json "$WS/backend/out/report.csv")" "positive: subproject out/"
expect allow "$PW" "$(bash_json "cat www/static/legal/avv-de-v1.2.pdf | head -c 100")" "positive: reading is fine"
expect allow "$PW" "$(edit_json "$WS/planning/plans/2026-08-24-x.md")" "positive: a plan"

export HARNESS_RULES=$SAVED_RULES; rm -f "$NOPHASE"

echo "== check-tickets-after-change (Stop hook with state)"
stop_json=$(jq -n '{session_id:"t1",hook_event_name:"Stop"}')
expect_exit 0 "clean session may stop" "$TS" stop <<<"$stop_json"
"$TS" post <<<"$(bash_json "$P/bin/set-status review backend#12")" >/dev/null
expect_exit 2 "dirty session is blocked" "$TS" stop <<<"$stop_json"
"$TS" post <<<"$(bash_json "$P/bin/check-tickets")" >/dev/null
expect_exit 0 "check-tickets clears it" "$TS" stop <<<"$stop_json"
failed_dirty=$(bash_json "$P/bin/set-status review backend#12" | jq '.session_id="codex-failed"')
failed_check=$(bash_json "$P/bin/check-tickets" | jq '.session_id="codex-failed" | .tool_response={exit_code:1}')
failed_stop=$(jq -n '{session_id:"codex-failed",hook_event_name:"Stop"}')
"$TS" post <<<"$failed_dirty" >/dev/null
"$TS" post <<<"$failed_check" >/dev/null
expect_exit 2 "Codex failed check-tickets stays dirty" "$TS" stop <<<"$failed_stop"
"$TS" post <<<"$(bash_json "$P/bin/add-ticket --title x --estimate 1")" >/dev/null
"$TS" stop <<<"$stop_json" >/dev/null 2>&1; "$TS" stop <<<"$stop_json" >/dev/null 2>&1; "$TS" stop <<<"$stop_json" >/dev/null 2>&1
expect_exit 0 "ceiling: 4th stop passes with a systemMessage" "$TS" stop <<<"$stop_json"

echo "== operator switch (HARNESS_OFF marker)"
export HARNESS_OFF=$(mktemp -u)
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add -A")" "switch absent = harness on"
touch "$HARNESS_OFF"
expect allow "$PB" "$(bash_json "git -C $P add -A")" "off: pre-bash makes no decision"
expect allow "$PW" "$(edit_json "$WS/www/static/legal/avv-de-v1.2.pdf")" "off: pre-write makes no decision"
"$TS" post <<<"$(bash_json "$P/bin/set-status review backend#12")" >/dev/null
expect_exit 0 "off: a dirty ticket session may stop" "$TS" stop <<<"$(jq -n '{session_id:"t1"}')"
out=$("$H" hook stop-checks <<<'{"session_id":"t1"}' 2>&1); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [off: stop-checks silent]"; }
out=$(CLAUDE_PROJECT_DIR=$WS HARNESS_AGENT_DIR=$(mktemp -d) "$H" status | head -1); grep -q 'OFF' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [off: status says OFF] $out"; }
rm -f "$HARNESS_OFF"
expect deny:git-stage-explicit "$PB" "$(bash_json "git -C $P add -A")" "on again: denies"
"$TS" post <<<"$(bash_json "$P/bin/check-tickets")" >/dev/null
unset HARNESS_OFF

echo "== project overlay merge"
OV=$(mktemp)
run_ov() { HARNESS_PROJECT_RULES=$OV "$@"; }   # hooks with an alternative overlay
jq '.disabled=["db-no-improvise"]' "$HARNESS_PROJECT_RULES" >"$OV"
out=$(run_ov "$PB" <<<"$(bash_json 'initdb -D /tmp/pg')"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: disabled removes a generic rule]"; }
jq '.rules += [{"id":"no-production-push","class":"enforce","step":"release","trigger":"pre_bash","text":"live is production here","check":{"regex":"\\bgit(\\s+-[cC]\\s+\\S+)*\\s+push\\b[^|;&]*\\blive\\b"}}]' "$HARNESS_PROJECT_RULES" >"$OV"
out=$(run_ov "$PB" <<<"$(bash_json "git -C $P push origin live")"); grep -q 'no-production-push' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: same id replaces the generic rule]"; }
out=$(run_ov "$PB" <<<"$(bash_json "git -C $P push origin production")"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: replaced rule no longer matches the generic branch]"; }
jq '.protected_paths=["planning/frozen/*"]' "$HARNESS_PROJECT_RULES" >"$OV"
out=$(run_ov "$PW" <<<"$(edit_json "$WS/planning/frozen/x.md")"); grep -q 'protected-paths' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: protected_paths extend]"; }
out=$(run_ov "$PW" <<<"$(edit_json "$WS/planning/.devcontainer/x")"); grep -q 'protected-paths' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: generic protected paths survive the extension]"; }
echo '{ corrupt' >"$OV"
out=$(run_ov "$PB" <<<"$(bash_json 'ls')"); grep -q 'harness-registry' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: corrupt overlay fails closed]"; }
out=$(HARNESS_PROJECT_RULES=/nonexistent "$PB" <<<"$(bash_json 'initdb x')"); grep -q 'db-no-improvise' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [no overlay: generic registry alone works]"; }
jq '.rules += [{"id":"bad-regex","class":"enforce","step":"ops","trigger":"pre_bash","text":"x","check":{"regex":"("}}]' "$HARNESS_PROJECT_RULES" >"$OV"
out=$(run_ov "$PB" <<<"$(bash_json 'ls')"); grep -q 'harness-registry' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [overlay: a regex that does not compile fails closed]"; }
out=$(HARNESS_RULES=/nonexistent "$PB" <<<"$(bash_json 'ls')"); grep -q 'harness-registry' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [generic registry missing fails closed]"; }
rm -f "$OV"

# real fail-closed checks: unreadable registry denies, crashing jq path denies
out=$(HARNESS_RULES=/nonexistent "$PB" <<<"$(bash_json 'ls')"); [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [fail-closed] missing registry did not deny"; }
out=$(HARNESS_RULES=/nonexistent "$PW" <<<"$(edit_json "$WS/README.md")"); [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [fail-closed] pre-write missing registry did not deny"; }
tmp=$(mktemp); echo '{ not json' >"$tmp"
out=$(HARNESS_RULES=$tmp "$PB" <<<"$(bash_json 'ls')"); rm -f "$tmp"; [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [fail-closed] corrupt registry did not deny"; }


echo "== phase-gate (the operator's process: brainstorm -> plan -> review -> approval -> implement)"
T=$(mktemp -d -p "${HOME:-/var/tmp}/.cache"); mkdir -p "$T/planning/plans" "$T/planning/docs" "$T/backend/src" "$T/backend/docs"
git -C "$T/planning" init -q && git -C "$T/planning" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
export CLAUDE_PROJECT_DIR=$T HARNESS_AGENT_DIR=$T/.agent HARNESS_APPROVAL_DIR=$T/.approvals
PLAN=planning/plans/2026-08-24-x.md
tj() { jq -n --arg f "$1" --arg cwd "$T" '{session_id:"t2",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$f,content:"x"}}'; }
tb() { jq -n --arg c "$1" --arg cwd "$T" '{session_id:"t2",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'; }
tp() { jq -n --arg c "$1" --arg cwd "$T" '{session_id:"t2",tool_name:"apply_patch",cwd:$cwd,tool_input:{command:$c}}'; }
gitp() { git -C "$T/planning" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# brainstorm (no state at all = fail closed to the most restrictive phase)
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "brainstorm: code denied"
expect deny:phase-gate "$PW" "$(tp '*** Begin Patch
*** Update File: backend/src/x.py
*** End Patch')" "brainstorm: Codex patch denied"
expect allow "$PW" "$(tj "$T/planning/docs/idea.md")" "brainstorm: planning md allowed"
expect allow "$PW" "$(tj "$T/backend/docs/notes.md")" "brainstorm: docs md allowed"
expect allow "$PW" "$(tj "/tmp/scratch.txt")" "brainstorm: /tmp allowed"
mkdir -p "$T/backend/src" && echo "print(1)" >"$T/backend/src/x.py" && echo "# api" >"$T/backend/API.md"
expect allow "$PW" "$(tb "find backend -name '*.py' 2>/dev/null")" "brainstorm: a read with 2>/dev/null is not a write (transcript 2026-08-24)"
expect allow "$PW" "$(tb "harness status && cat backend/API.md 2>/dev/null")" "brainstorm: cat is not a write (transcript)"
expect allow "$PW" "$(tb "grep -rn foo backend/src | head")" "brainstorm: grep is not a write"
expect allow "$PW" "$(tb "sed -n 1p backend/src/x.py")" "brainstorm: sed without -i is a read"
expect allow "$PW" "$(tb "cp backend/src/x.py /tmp/x.py")" "brainstorm: cp OUT of the workspace"
expect allow "$PW" "$(tb "cat backend/src/x.py 2>&1 | wc -l")" "brainstorm: 2>&1 is not a redirect into a file"
expect deny:phase-gate "$PW" "$(tb "cp /tmp/x.py backend/src/x.py")" "brainstorm: cp INTO the workspace"
expect deny:phase-gate "$PW" "$(tb "mv backend/src/x.py backend/src/y.py")" "brainstorm: mv"
expect deny:phase-gate "$PW" "$(tb "sed -i s/a/b/ backend/src/x.py")" "brainstorm: sed -i"
expect deny:phase-gate "$PW" "$(tb "make test 2>&1 | tee backend/src/x.py")" "brainstorm: tee"
expect deny:phase-gate "$PW" "$(tb "truncate -s0 backend/src/x.py")" "brainstorm: truncate"
expect deny:phase-gate "$PW" "$(tb "rm backend/src/x.py")" "brainstorm: rm"
expect deny:phase-gate "$PW" "$(tb "git -C $T/backend rm src/x.py")" "bypass: git -C repo rm path-relative-to-repo"
expect deny:phase-gate "$PW" "$(tb "echo x 1> backend/src/x.py")" "bypass: 1> redirect"
expect deny:phase-gate "$PW" "$(tb "echo x &> backend/src/x.py")" "bypass: &> redirect"
expect deny:phase-gate "$PW" "$(tb "echo x > backend/src/x.py")" "bypass: redirect in brainstorm"
# shell forms the parser must not mistake for write targets (agent feedback 2026-08-24)
expect allow "$PW" "$(tb "sed -i 's|a|b|' planning/docs/idea.md")" "brainstorm: a | inside the sed script is not a pipe"
expect allow "$PW" "$(tb "git -C $T/planning commit -m 'x > y; rm -rf z'")" "brainstorm: operators inside a quoted message are text"
expect allow "$PW" "$(tb "git remote -v && git -C $T/backend status")" "brainstorm: git remote -v is a read"
expect allow "$PW" "$(tb "mkdir -p \"\$OUT/x\" && echo x > \$OUT/x/y.py")" "brainstorm: an unexpanded \$VAR is the shell's, not judged"
expect deny:phase-gate "$PW" "$(tb "sed -i 's|a|b|' backend/src/x.py")" "brainstorm: sed -i with a | script still finds its file"
expect deny:phase-gate "$PW" "$(tb "sed -i -e 's/a/b/' backend/src/x.py")" "brainstorm: sed -i -e"
expect deny:phase-gate "$PW" "$(tb "echo x >'backend/src/x.py'")" "brainstorm: quoted, attached redirect target"
expect deny:phase-gate "$PW" "$(tb "cp /tmp/a.py \"backend/src/x.py\"")" "brainstorm: quoted cp target"
expect deny:phase-gate "$PW" "$(tb "cat <<EOF > backend/src/x.py
print(1)
EOF")" "bypass: heredoc in brainstorm"
# plan needs a ticket
expect_exit 1 "phase plan without ticket refused" "$H" phase plan
expect_exit 0 "phase plan with ticket" "$H" phase plan --ticket backend#12
st=$("$H" steps); grep -q '^▶ plan' <<<"$st" && grep -q '^  brainstorm' <<<"$st" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [steps marks the current phase]"; }
rl=$("$H" rules --step commit); grep -q 'git-stage-explicit' <<<"$rl" && ! grep -q 'phase-gate' <<<"$rl" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [rules --step filters]"; }
[ "$("$H" rules | tail -n +2 | wc -l)" -eq "$("$H" status | sed -nE 's/^rules:  ([0-9]+).*/\1/p')" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [rules lists every rule]"; }
expect allow "$PW" "$(tj "$T/$PLAN")" "plan: the plan file allowed"
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "plan: code still denied"
# review needs a committed plan and the ponytail declaration
echo "# plan" > "$T/$PLAN"
expect_exit 1 "review with uncommitted plan refused" "$H" phase review --plan "$PLAN" --ponytail-reviewed
gitp add plans/2026-08-24-x.md && gitp commit -q -m "plan"
expect_exit 1 "review without ponytail declaration refused" "$H" phase review --plan "$PLAN"
expect_exit 0 "review with committed plan + ponytail" "$H" phase review --plan "$PLAN" --ponytail-reviewed
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "review: code denied"
expect allow "$PW" "$(tj "$T/$PLAN")" "review: plan revisions allowed"
# implement needs the operator's token
expect_exit 1 "implement without approval refused" "$H" phase implement
expect_exit 0 "operator approves" "$H" approve "$PLAN"
expect_exit 0 "implement with approval" "$H" phase implement
expect allow "$PW" "$(tj "$T/backend/src/x.py")" "implement: code allowed"
expect allow "$PW" "$(tb "echo x > backend/src/x.py")" "implement: redirect allowed"
# a plan edited after approval drops the phase back
echo "more" >> "$T/$PLAN"
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "stale: dirty plan after approval drops to review"
gitp add plans/2026-08-24-x.md && gitp commit -q -m "plan v2"
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "stale: committed change after approval still drops to review"
expect_exit 1 "re-declaring implement on a stale approval refused" "$H" phase implement
"$H" approve "$PLAN" >/dev/null && "$H" phase implement >/dev/null
expect allow "$PW" "$(tj "$T/backend/src/x.py")" "re-approved: code allowed again"
# protected paths still win inside implement
expect deny:protected-paths "$PW" "$(tj "$T/planning/.devcontainer/allowlist.txt")" "implement: policy file still read-only"
# fail closed: unreadable run state = brainstorm
chmod 000 "$HARNESS_AGENT_DIR/run.json"
expect deny:phase-gate "$PW" "$(tj "$T/backend/src/x.py")" "fail closed: unreadable state is brainstorm"
chmod 644 "$HARNESS_AGENT_DIR/run.json"

. "$HERE/checks.sh"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
