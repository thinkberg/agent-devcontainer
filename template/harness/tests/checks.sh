# tests/checks.sh — sourced by run.sh: the checker-backed rules.
# Uses expect / expect_exit / pass / fail from run.sh. Every temp repo is
# created under ~/.cache (the phase gate always-allows /tmp).

W=$(mktemp -d -p "$HOME/.cache"); export CLAUDE_PROJECT_DIR=$W HARNESS_AGENT_DIR=$W/.agent HARNESS_APPROVAL_DIR=$W/.approvals
CK=$HERE/../checkers; post() { "$H" hook post-write "$@"; }; stop_() { "$H" hook stop-checks "$@"; }; POST=post; STOP=stop_
mkrepo() { mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" commit -q --allow-empty -m init; }
gq() { git -C "$1" "${@:2}"; }
wj() { jq -n --arg f "$1" --arg cwd "$W" '{session_id:"t3",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$f,content:"x"}}'; }
bj() { jq -n --arg c "$1" --arg cwd "${2:-$W}" '{session_id:"t3",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'; }
# expect_rc <code> <label> <cmd...>  (stdin from /dev/null)
expect_rc() { local want=$1 label=$2; shift 2; "$@" >/dev/null 2>&1 </dev/null; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [$label] wanted exit $want, got $got"; fi; }
mkrepo "$W/planning"; mkrepo "$W/specs"; mkrepo "$W/deployment"; mkrepo "$W/backend"; mkrepo "$W/app"; mkdir -p "$W/www"
B=$W/backend; A=$W/app; P=$W/planning; S=$W/specs; D=$W/deployment
MERGED=$(mktemp); "$H" rules --json >"$MERGED"   # what the dispatcher hands a checker
ckm() { HARNESS_RULES=$MERGED "$CK/$1" "${@:2}"; }   # a checker that reads its config from the registry

echo "== spec-section-stability"
S=$W/specs; printf '# Spec\n## 1 Scope\n## 2 Terms\n### 2.1 Words\n## 3 Rules\n' >"$S/03_x.md"; gq "$S" add 03_x.md; gq "$S" commit -q -m spec
printf '# Spec\n## 1 Scope\n## 2 Terms\n### 2.1 Words\n## 3 Rules\n## 4 More\n' >"$S/03_x.md"
expect_rc 0 "adding a section passes" "$CK/spec-section-stability" "$S"
printf '# Spec\n## 1 Scope\n## 2 Rules\n' >"$S/03_x.md"
expect_rc 1 "renumbering (3→2, 2.1 gone) fails" "$CK/spec-section-stability" "$S"
printf '# Spec\n## 1 Scope\n## 2 Terms (Deleted in V4)\n### 2.1 Words (Deleted in V4)\n## 3 Rules\n' >"$S/03_x.md"
expect_rc 0 "deleted content keeps its header" "$CK/spec-section-stability" "$S"
gq "$S" commit -q -am "v4"; printf '# Spec\n## 1 Scope\n## 3 Rules\n' >"$S/03_x.md"; gq "$S" commit -q -am "bad"
expect_rc 1 "--base mode sees the committed renumbering" "$CK/spec-section-stability" "$S" --base HEAD~1
gq "$S" checkout -q HEAD~1 -- 03_x.md; gq "$S" commit -q -am restore
out=$("$POST" <<<"$(wj "$S/03_x.md")" 2>&1); [ $? -eq 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: clean spec edit passes]"; }
printf '# Spec\n## 1 Scope\n' >"$S/03_x.md"
out=$("$POST" <<<"$(wj "$S/03_x.md")" 2>&1); rc=$?; [ $rc -eq 2 ] && grep -q 'spec-section-stability' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: spec renumbering reported] rc=$rc"; }
gq "$S" checkout -q -- 03_x.md

echo "== review-tick-has-date"
P=$W/planning; mkdir -p "$P/reviews"; printf -- '- [ ] item a\n- [ ] item b\n' >"$P/reviews/2026-08-24-r.md"; gq "$P" add reviews; gq "$P" commit -q -m review
printf -- '- [x] item a\n- [ ] item b\n' >"$P/reviews/2026-08-24-r.md"
expect_rc 1 "tick without date fails" "$CK/review-tick-has-date" "$P/reviews/2026-08-24-r.md"
printf -- '- [x] item a\n  Review 2026-08-24: accepted, no change\n- [ ] item b\n' >"$P/reviews/2026-08-24-r.md"
expect_rc 0 "tick with dated note passes" "$CK/review-tick-has-date" "$P/reviews/2026-08-24-r.md"
printf -- '- [x] new\n' >"$P/reviews/2026-08-25-new.md"
expect_rc 1 "untracked file with a bare tick fails" "$CK/review-tick-has-date" "$P/reviews/2026-08-25-new.md"
out=$("$POST" <<<"$(wj "$P/reviews/2026-08-25-new.md")" 2>&1); [ $? -eq 2 ] && grep -q 'review-tick-has-date' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: review tick reported]"; }
rm "$P/reviews/2026-08-25-new.md"; gq "$P" checkout -q -- reviews

echo "== chrome-no-sandbox"
E=$A/e2e.spec.ts
printf "const b = await chromium.launch({ channel: 'chrome' });\n" >"$E"
expect_rc 1 "launch without the flag fails" "$CK/chrome-no-sandbox" "$E"
printf "const args = ['--no-sandbox'];\nconst b = await chromium.launch({ channel: 'chrome', args });\n" >"$E"
expect_rc 0 "flag anywhere in the file passes" "$CK/chrome-no-sandbox" "$E"
printf "export const x = 1;\n" >"$E"
expect_rc 0 "no launch = nothing to say" "$CK/chrome-no-sandbox" "$E"
printf "browser = p.chromium.launch(channel='chrome')\n" >"$A/shot.py"
expect_rc 1 "python launch without the flag fails" "$CK/chrome-no-sandbox" "$A/shot.py"
printf "const b = await puppeteer.launch();\n" >"$E"
out=$("$POST" <<<"$(wj "$E")" 2>&1); rc=$?; [ $rc -eq 2 ] && grep -q 'chrome-no-sandbox' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: chrome launch without --no-sandbox reported] rc=$rc"; }
rm -f "$E" "$A/shot.py"

echo "== hugo-warning-clean"
FB=$(mktemp -d -p "$HOME/.cache"); export PATH=$FB:$PATH
expect_rc 3 "no hugo = error (fail closed in the dispatcher)" env PATH=/usr/bin:/bin "$CK/hugo-warning-clean" "$W/www"
printf '#!/bin/sh\necho "WARN deprecated: .Site.Data was deprecated in Hugo v0.120.0"\n' >"$FB/hugo"; chmod +x "$FB/hugo"
expect_rc 1 "a deprecation warning fails" "$CK/hugo-warning-clean" "$W/www"
printf '#!/bin/sh\necho "Total in 42 ms"\n' >"$FB/hugo"
expect_rc 0 "clean build passes" "$CK/hugo-warning-clean" "$W/www"
mkdir -p "$W/www/layouts"; printf '#!/bin/sh\necho "WARN x"\n' >"$FB/hugo"
out=$("$POST" <<<"$(wj "$W/www/layouts/index.html")" 2>&1); [ $? -eq 2 ] && grep -q 'hugo-warning-clean' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: layouts edit runs the build check]"; }
out=$("$POST" <<<"$(wj "$W/www/content/de/x.md")" 2>&1); [ $? -eq 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [post-write: content edit does not run it]"; }

echo "== checklist-upkeep"
D=$W/deployment; mkdir -p "$D/ansible"; echo x >"$D/CHECKLIST.md"; echo x >"$D/ansible/site.yml"; gq "$D" add .; gq "$D" commit -q -m c
expect_rc 0 "nothing changed passes" "$CK/checklist-upkeep" "$D"
echo y >"$D/ansible/site.yml"
expect_rc 1 "ansible changed, checklist not" "$CK/checklist-upkeep" "$D"
echo y >"$D/CHECKLIST.md"
expect_rc 0 "both changed passes" "$CK/checklist-upkeep" "$D"
gq "$D" commit -q -am both

printf 'backend_tag: v1.0.0\napp_tag: v1.0.0\n' >"$D/ansible/versions.yml"; gq "$D" add ansible; gq "$D" commit -q -m pin; gq "$B" tag v1.0.0; gq "$A" tag v1.0.0
echo "== hotfix-must-land"
expect_rc 0 "clean, all merged" "$CK/hotfix-must-land" "$D"
gq "$D" checkout -q -b hotfix/udp443; echo z >"$D/ansible/site.yml"; gq "$D" commit -q -am hotfix; gq "$D" checkout -q main
expect_rc 1 "unmerged hotfix branch fails" "$CK/hotfix-must-land" "$D"
expect deny:hotfix-must-land "$PB" "$(bj "ansible-playbook -i inventory site.yml" "$D")" "pre-bash: ansible run denied while a hotfix dangles"
expect allow "$PB" "$(bj "ansible-playbook -i inventory site.yml --check --diff" "$D")" "pre-bash: --check dry run allowed"
gq "$D" merge -q hotfix/udp443; gq "$D" branch -q -d hotfix/udp443
expect allow "$PB" "$(bj "ansible-playbook -i inventory site.yml" "$D")" "pre-bash: allowed once landed"
echo dirty >>"$D/CHECKLIST.md"
expect_rc 1 "dirty tree before ansible fails" "$CK/hotfix-must-land" "$D"
gq "$D" checkout -q -- CHECKLIST.md

echo "== versions-repin"
expect_rc 0 "pins match latest tags" ckm versions-repin "$D"
gq "$B" tag v1.0.1
expect_rc 1 "backend released v1.0.1, yml still v1.0.0" ckm versions-repin "$D"
expect deny:versions-repin "$PB" "$(bj "ansible-playbook site.yml" "$D")" "pre-bash: playbook would roll back — denied"
sed -i 's/backend_tag: v1.0.0/backend_tag: v1.0.1/' "$D/ansible/versions.yml"; gq "$D" commit -q -am repin
expect_rc 0 "re-pinned passes" ckm versions-repin "$D"

echo "== release-ships-tip (approval token bound to the PR head)"
export FAKE_PRVIEW=$(mktemp); echo '{"baseRefName":"production","headRefOid":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}' >"$FAKE_PRVIEW"
cp "$HERE/fake-gh" "$FB/gh"
expect deny:release-ships-tip "$PB" "$(bj "gh pr merge 7 --merge" "$B")" "merge to production without approval denied"
mkdir -p "$HARNESS_APPROVAL_DIR"; printf %s aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111 >"$HARNESS_APPROVAL_DIR/release-backend-7.approved"   # what dcc approve-release stores
expect allow "$PB" "$(bj "gh pr merge 7 --merge" "$B")" "merge with matching approval allowed"
echo '{"baseRefName":"production","headRefOid":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"}' >"$FAKE_PRVIEW"
expect deny:release-ships-tip "$PB" "$(bj "gh pr merge 7 --merge" "$B")" "main moved after approval — stale, denied"
echo '{"baseRefName":"main","headRefOid":"cccc"}' >"$FAKE_PRVIEW"
expect allow "$PB" "$(bj "gh pr merge 8 --squash" "$B")" "a PR to main needs no release approval"
expect deny:release-ships-tip "$PB" "$(bj "gh pr merge" "$B")" "merge without a PR number denied"

echo "== scope-to-project (approval carries the write scope)"
PL=planning/plans/2026-08-24-s.md; mkdir -p "$P/plans"; echo "# s" >"$P/plans/2026-08-24-s.md"
gq "$P" add plans; gq "$P" commit -q -m plan
"$H" phase plan --ticket backend#142 >/dev/null && "$H" phase review --plan "$PL" --ponytail-reviewed >/dev/null
expect_rc 0 "approve with a scope" "$H" approve "$PL" --scope 'backend/*'
"$H" phase implement >/dev/null
expect allow "$PW" "$(wj "$B/src/x.py")" "inside scope allowed"
expect deny:scope-to-project "$PW" "$(wj "$A/app/routes/x.tsx")" "outside scope denied"
mkdir -p "$A/app/internal" && touch "$A/app/internal/api.md"
expect deny:scope-to-project "$PW" "$(bj "sed -i s/a/b/ app/app/internal/api.md")" "bypass: sed outside scope denied"
# a heredoc body is data: markdown quotes, redirects and verbs in it are not write targets (incident 2026-08-24)
expect allow "$PW" "$(bj "cat > backend/API.md <<'EOF'
# API
> Note: never rm -rf app/app
curl -s http://x | jq . > app/out.json
mv app/a app/b
EOF")" "heredoc body is not parsed for write targets"
expect deny:scope-to-project "$PW" "$(bj "cat <<'EOF' > app/out.md
x
EOF")" "heredoc: the redirect on the command line still counts"
expect allow "$PW" "$(wj "$P/DONE.md")" "planning md writable in implement without being in the scope (archive/DONE step)"
expect allow "$PW" "$(bj "git -C $P mv plans/2026-08-24-s.md archive/2026-08-24-s.md")" "archiving the plan is allowed in implement"

echo "== stop-checks dispatcher"
echo y >"$D/ansible/site.yml"   # deployment requirement changed, CHECKLIST not → warn; dirty tree → block
out=$("$STOP" <<<'{"session_id":"t3"}' 2>&1); rc=$?; grep -q 'deployment-clean-at-stop' <<<"$out" && grep -q 'checklist-upkeep' <<<"$out" && [ $rc -eq 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [stop: block rule blocks, warn rule reported alongside] rc=$rc"; }
out=$("$STOP" <<<'{"session_id":"t3"}' 2>&1); rc=$?; [ $rc -eq 0 ] && grep -q 'checklist-upkeep' <<<"$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [stop: blocks once per session, then warns] rc=$rc"; }
gq "$D" checkout -q -- ansible
out=$("$STOP" <<<'{"session_id":"t4"}' 2>&1); rc=$?; [ $rc -eq 0 ] && [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [stop: clean tree, nothing to say] rc=$rc"; }

echo "== stop: a rule with paths binds only to what the session touched"
printf '# Spec\n## 1 Scope\n' >"$S/03_x.md"     # a renumbering violation exists in the tree
out=$("$STOP" <<<'{"session_id":"t6"}' 2>&1); rc=$?; ! grep -q 'spec-section-stability' <<<"$out" && [ $rc -eq 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [stop: untouched spec drift does not block this session] rc=$rc: $out"; }
"$POST" <<<"$(jq -n --arg f "$S/03_x.md" --arg cwd "$W" '{session_id:"t6",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$f}}')" >/dev/null 2>&1   # the session edits the spec
out=$("$STOP" <<<'{"session_id":"t6"}' 2>&1); rc=$?; grep -q 'spec-section-stability' <<<"$out" && [ $rc -eq 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [stop: touched spec drift blocks] rc=$rc"; }
out=$("$PW" <<<"$(jq -n --arg c "sed -i s/a/b/ planning/DONE.md" --arg cwd "$W" '{session_id:"t7",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}')"); [ -z "$out" ] && grep -q 'planning/DONE.md' "$HARNESS_AGENT_DIR/t7.touched" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [pre-write records an allowed Bash write target as touched] $out"; }
out=$("$PW" <<<"$(jq -n --arg c "sed -i s/a/b/ specs/03_x.md" --arg cwd "$W" '{session_id:"t8",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}')"); grep -q 'scope-to-project' <<<"$out" && [ ! -f "$HARNESS_AGENT_DIR/t8.touched" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [a denied write is not recorded as touched]"; }
gq "$S" checkout -q -- 03_x.md

echo "== ste-compliant (optional: needs ste100; tests/fake-ste100 stands in)"
mkdir -p "$W/docs"; printf '# Guide\n\nUse the tool.\n\n<!-- ste: procedure -->\n\n## Steps\n\n1. Run `x`.\n' >"$W/docs/g.md"
expect_rc 3 "no ste100 = error (fail closed in the dispatcher)" env PATH=/usr/bin:/bin "$CK/ste-compliant" "$W/docs/g.md"
cp "$HERE/fake-ste100" "$FB/ste100"; export FAKE_STE_LOG=$W/ste.log
expect_rc 0 "clean markdown passes" "$CK/ste-compliant" --glossary /dev/null "$W/docs"
grep -q '^description$' "$FAKE_STE_LOG" && grep -q '^procedure$' "$FAKE_STE_LOG" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [ste: the marker switches the text type]"; }
printf '# Guide\n\nUtilise the tool.\n' >"$W/docs/g.md"
expect_rc 1 "an unapproved word fails" "$CK/ste-compliant" "$W/docs/g.md"

echo "== harness check (the gate's dry run)"
gq "$B" tag v1.0.2   # drift again: released past the pin
out=$("$H" check 2>&1); rc=$?; grep -q 'FAIL  versions-repin' <<<"$out" && grep -q 'ok    hotfix-must-land' <<<"$out" && [ $rc -eq 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [check: reports the failing rule, exit 1] rc=$rc"; echo "$out"; }
sed -i "s/backend_tag: v1.0.1/backend_tag: v1.0.2/" "$D/ansible/versions.yml"; gq "$D" commit -q -am repin2
printf -- '- [x] gate\n' >"$P/reviews/2026-08-26-gate.md"
out=$("$H" check 2>&1); rc=$?; grep -q 'FAIL  review-tick-has-date.*2026-08-26-gate.md' <<<"$out" && grep -q '(2 files)' <<<"$out" && [ $rc -eq 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [check: a per-file rule runs over the matching workspace files] rc=$rc"; echo "$out"; }
rm "$P/reviews/2026-08-26-gate.md"
out=$("$H" check 2>&1); rc=$?; [ $rc -eq 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL [check: all ok exits 0]"; echo "$out"; }
rm -rf "$W" "$FB" "$FAKE_PRVIEW" "$MERGED"
