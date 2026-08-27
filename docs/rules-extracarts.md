# The extracarts rule corpus, classified

Status: analysis and worked example. The engine and the generic rules
are in [`template/harness/`](../template/harness/); the extracarts-specific rules, paths
and checkers are the project overlay in
`extracarts-planning/.devcontainer/rules/` (project rules stay with
the project). Both are real and tested; the engine is installed in the
image ([safety-harness.md](safety-harness.md) §14, P0).

This document uses the rules of
[Simplified Technical English](https://en.wikipedia.org/wiki/Simplified_Technical_English).

## 1. Purpose

The extracarts workspace has rules in many markdown files. An agent must
obey them at different steps of the work. This document does three
things:

1. It states the working process as a state machine and attaches each
   rule to the step where it applies.
2. It classifies each rule: can software enforce it, can software verify
   it after the fact, must a human approve it, or does it stay prose?
3. It shows the rules compiled into working hooks, with tests.

The classification is the important part. A rule that software cannot
test stays a human decision. The document says so, rule by rule, so that
nobody believes more than the harness gives.

## 2. Sources read

| Source | Lines | Holds |
|--------|-------|-------|
| `CLAUDE.md`, `AGENTS.md` (workspace root) | 13, 41 | The map. Pointers only. |
| `extracarts-planning/AGENTS.md` | 113 | The canonical shared rules. |
| `extracarts-planning/TICKETS.md` | 87 | The ticket workflow and the `bin/` scripts. |
| `extracarts-planning/CLAUDE.md` | 10 | Plan format, archive flow, DONE.md. |
| `extracarts-specs/CLAUDE.md` | 21 | Seven rules for editing the specs. |
| `www.extracarts.com/CLAUDE.md` | 138 | Build, legal release flow, immutable paths, parity. |
| `www.extracarts.com/docs/content-styleguide.md` §7–8 | 32 | The grammar gate and the translation gate. |
| `extracarts-deployment/CHECKLIST.md` | 392 | Release mechanics, gates, smoke test. |
| `.claude-devcontainer/settings.json` | 90 | The agent's own hooks. Agent-writable. |
| `.claude-devcontainer/projects/…/memory/` | 28 files | Feedback memories. Each one is a rule born from an incident, with the date. |
| `~/.claude/projects/-…-extracarts/memory/` | 23 files | The host-side copy, with git rules the container copy lacks. |
| The operator, 2026-08-24 | — | The working process itself (section 3). |

The memory files are the best material in the corpus. A rule in
AGENTS.md says what to do. A feedback memory says what went wrong, when,
and what it cost. That is what a negative test needs.

## 3. The working process

The operator's process, in their words: brainstorming and discussion (no
code changes, maybe markdown files) → make a plan (commit it, check it
with ponytail) → review of the plan by the operator → approval →
implement. The process must follow the ticket rules and the general
guidelines and must never skip a step.

That is a state machine: the generic phase machine of the harness,
with its preconditions, the root-owned approval token and the stale-token
rule ([harness-ste.md](harness-ste.md) A.8). The extracarts overlay
narrows it:

| Key | extracarts value |
|-----|------------------|
| `plan_glob` | `planning/plans/*.md` |
| `ticket_regex` | `^(backend\|app\|deploy\|www)#[0-9]+$` |
| `allow_write` before implement | markdown in `extracarts-planning/` and any `docs/*.md` |

The later steps follow implement. Each rule in section 4 names its step.

| Step | What happens | Rules that apply |
|------|--------------|------------------|
| intake | A ticket is created or changed | `bin/` only; sub-issues native; estimates and milestones; `check-tickets` after |
| plan / review | See the state machine | phase gate; plan file; ponytail; approval token |
| implement | Code is edited | scope to project; venv; check docs; no over-engineering; backend invariants; no PII in logs; protected paths; no DB improvisation |
| verify | Tests and checkers run | focused tests first; warning-clean build; DE/EN parity; spec headings stable; contract copies in sync |
| commit | A commit is made | explicit paths; `-C /absolute`; no bypass flags; grammar gate (www); legal version bump |
| publish | A push or PR happens | no session links; no remote rewrite; stop on push failure; Status Review |
| release | main goes to production | Release PR only; tip-of-main confirmation; versions.yml re-pin; hotfix branches landed |
| close | A ticket is closed | `bin/close-ticket`; DONE.md line; plan to `archive/`; review ticks carry a date |
| ops | Secrets, databases, mail | secrets by the operator only; no live mail except to one address; ask when the DB is down |

## 4. Classification

Four classes:

- **enforce** — a control blocks the violation before it happens.
- **verify** — a checker tests the result; the gate refuses on failure.
- **approve** — a human decides; the harness only proves the decision exists.
- **advise** — prose. Useful. No guarantee.

The column "Guarantee" names the control that holds even if the hook is
bypassed. Where it says *hook only*, the rule has feedback but no
guarantee yet, and the row says what would give one.

### 4.1 Enforce — 14 rules, all mechanized in `harness/rules.json`

| Rule | Step | Incident | Hook | Guarantee |
|------|------|----------|------|-----------|
| `phase-gate` — writes follow the phase | plan | (the operator's process) | `pre-write` builtin | the token directory is root-owned; the agent can declare phases but cannot approve |
| `plan-file-first` — code needs a committed plan | plan | 2026-07-21: a plan approved in-session only, written retroactively | same | same |
| `plan-approval-not-go` — approval is a token, not a chat message | plan | (memory) | same | same |
| `scope-to-project` — in implement, writes stay inside the scope given with the approval | implement | (AGENTS.md) | same; `dcc approve <plan> --scope <glob>…` | same: the scope lives in the root-owned token |
| `git-stage-explicit` — never `add -A/-u/.`, never `commit -a` | commit | 2026-07-22: `add -A` swept another session's edits onto planning main | `pre-bash` regex | hook only; the gate's diff-scope check (plan P4) is the guarantee |
| `git-c-absolute` — mutating git names its repo with `-C /abs` | commit | 2026-07-17: a `cd` did not persist; a commit landed on app main | `pre-bash` builtin | hook only; same |
| `git-no-bypass` — no `--no-verify`, `--no-gpg-sign`, hooksPath override | commit | (self-protection) | `pre-bash` regex | hook only by design; git hooks are not the gate |
| `no-production-push` — Release PR from main, never a push | release | (AGENTS.md) | `pre-bash` regex | **none on GitHub**: the org plan has no branch protection (§6). The release workflow can refuse a non-merge commit — §7 |
| `git-remote-stable` — no `remote set-url`, no push to a URL, no credential helper | publish | one unwanted HTTPS fallback | `pre-bash` regex | in the container: the token file is read-only and there is no push key |
| `no-session-links` — nothing session-bound reaches GitHub | publish | 2026-08-22: 45 PR bodies and 162 commit messages scrubbed | `pre-bash` regex, scoped to `git commit/push` and `gh` | hook only; a CI job that greps the PR body and the commit messages is the guarantee (§7) |
| `tickets-via-bin` — create/close/status through `bin/` | intake, close | (TICKETS.md) | `pre-bash` regex; allows comments, body edits, transfers, `sub_issues`, `blocked_by` | hook only; `bin/check-tickets` is the verifier |
| `secrets-operator-only` — no `gh secret set`, `sops`, `age`, SQL passwords | ops | deploy#12 → #27: credentials burned through a transcript; 2026-07-24: secrets nearly uploaded | `pre-bash` regex, case-insensitive, command position | **resource level**: no age key in the container, secret files masked, prod host not on the allowlist |
| `db-no-improvise` — when the DB is down, ask | implement | 2026-08-22: `pgserver` + `initdb` instead of asking | `pre-bash` regex | hook only; acceptable — the damage is wasted time, not data |
| `protected-paths` — legal archives, PDFs, `public/`, root `out/`, policy files, workflows, own settings | implement | (www CLAUDE.md; outputs rule; self-protection) | `pre-write` glob on Edit/Write and a Bash heuristic | **read-only bind mount** per path in `devcontainer.json`, the mask technique the template already uses |

### 4.2 Verify — 13 rules; 10 mechanized here, 3 existing

Each checker follows the contract in `harness/checkers/README.md`.
`harness check` runs the `gate` ones on demand; that is the dry run of
the gate in plan P4.

| Rule | Step | Checker | Runs at |
|------|------|---------|---------|
| `check-tickets-after-change` | close | `ticket-state.sh`: a session that ran `add-ticket`/`set-status`/`close-ticket`/`update-estimates` cannot stop until `check-tickets` ran clean | Stop |
| `spec-section-stability` | verify | numbered headings of a changed spec file must all survive; a deleted section keeps its header with the marker | PostToolUse on `extracarts-specs/*.md`; gate with `--base` |
| `review-tick-has-date` | verify | a `[x]` added to `reviews/*.md` needs a `Review YYYY-MM-DD:` line in the same edit | PostToolUse on that path |
| `hugo-warning-clean` | verify | renders to a temp dir; any WARN/deprecated/error line fails; no hugo = error (failure) | PostToolUse on `hugo.toml`, `layouts/`, `data/`, `i18n/` |
| `api-contract-sync` | verify | coverage across three sources: every `/v1` path the app calls is a row in `extracarts-backend/API.md` and a backend route; every backend route is a row; every row is a route. `/admin` and `/webhooks` are dropped from all three sources — the webhooks are Shopify's and Brevo's contract, not the app's. Params normalized, queries dropped, test files and `include_in_schema=False` ignored | PostToolUse on `API.md`, the route files and the app's `.ts(x)`; Stop (blocks once); gate |
| `checklist-upkeep` | verify | `ansible/`, `portainer.yml`, workflows or compose changed and `CHECKLIST.md` not | Stop (warns), gate |
| `hotfix-must-land` | release | dirty tree or a branch with commits main lacks, before `ansible-playbook`; `--check` dry runs pass | PreToolUse on `ansible-playbook`; gate |
| `versions-repin` | release | `ansible/versions.yml` pins ≠ the latest `v*` tag of the code repo — the playbook would roll production back | PreToolUse on `ansible-playbook`; gate. The live comparison stays `bin/stack-status.py` |
| `sub-issues-native` | intake | "Sub-ticket of <ref>" in an open issue's body but absent from the parent's native `sub_issues` (via `gh`) | gate; drop-in for `bin/check-tickets` |
| `status-follows-pr` | publish | an open PR's ticket (closing refs, `task/<n>-` branch, `#n` in the title) not in Review; In Progress without assignee (via `gh`) | gate; drop-in for `bin/check-tickets` |
| `legal-version-bump` | release | `bin/check-legal-consistency.py` in `deploy.yaml` | **exists** — the model rule: prose, deterministic checker, CI gate |
| `de-en-parity` | verify | `bin/translate.py check`, exit 1 on drift | exists; wire like `hugo-warning-clean` when wanted |
| `grammar-gate` | commit | `bin/check-grammar.py` | exists; **host-only** — LanguageTool is not in the container |

### 4.3 Approve — 2 rules

| Rule | Step | What the harness holds |
|------|------|------------------------|
| `release-ships-tip` | release | `gh pr merge` of a PR whose base is `production` needs a token bound to the PR head SHA: `dcc approve-release <repo> <pr>` on the host. If main moved after the approval the token is stale and the merge is denied with the reason. Built, tested with a fake `gh`. |
| `ponytail-review-plan` | plan | No mechanical evidence exists that a skill ran meaningfully. The agent declares it (`--ponytail-reviewed`); the declaration is in the run state the operator sees before approving. A declaration, not proof. |

### 4.4 Advise — 9 rules, prose only

`ask-dont-assume`, `check-library-docs`, `no-over-engineering`,
`focused-tests-first`, `plan-format-ste`, `english-placeholders-lowercase`,
`memo-convention`, `no-pii-logging`, `backend-invariants` (the part tests
do not cover).

These stay in the digest that layer 1 renders. The digest marks them as
advice, so that a reader does not mistake them for guarantees.

## 5. Incidents → tests

Every dated incident in the memory files is a negative test in
`harness/tests/run.sh`. The bypass column is the test that matters most:
a control on a command string is not a control on the effect.

| Date | What happened | Test | Bypass test |
|------|---------------|------|-------------|
| 2026-07-17 | `cd x && git commit` in one call, `git push` in the next, on the wrong repo | `cd … && git commit` denied | `git -C ../relative` denied; `git -c opt commit` denied |
| 2026-07-21 | a plan approved in chat, implemented, written down afterwards | code write without a committed plan denied | `echo > src/x.py` and a heredoc redirect denied in brainstorm; a plan edited after approval drops the phase |
| 2026-07-22 | `git add -A` swept foreign edits into a commit | `add -A` denied | `add -u`, `add .`, `add --all`, `commit -am` denied |
| 2026-07-24 | secrets about to be uploaded with `gh secret set` | denied | `sops`, `age -d`, `alter role … password` in any case denied; `grep sops README` allowed |
| 2026-08-22 | 45 PR bodies, 162 commits with session links | `gh pr create --body …session…` denied | link in a heredoc commit message denied; `grep` for links allowed |
| 2026-08-22 | `initdb` instead of asking | denied | `pip install pgserver` denied; `pg_isready` allowed |
| (rule) | push to production | denied | `main:production` refspec and `HEAD:refs/heads/production` denied |
| (rule) | edit a legal archive | `Write` denied | `sed -i`, `cp`, `>` redirect, `git rm` on the path denied; `cat` allowed |
| (rule) | ticket change without `check-tickets` | Stop blocked | ceiling after 3 blocks, then a loud pass |
| (rule) | merge a Release PR without approval | denied, approval needed | main moved after approval → stale, denied; a PR to main needs none |
| (rule) | `ansible-playbook` with a dangling hotfix or stale `versions.yml` | denied | `--check` dry run allowed; landed branch allowed |
| (rule) | renumber a spec section; tick a review box without a date; a build warning | reported after the edit | a deleted section with its marker passes; content edits do not trigger the build |
| (rule) | write outside the approved scope | denied | `sed -i` outside the scope denied |
| (rule) | an app call, a route, or a doc row that the other two sources lack | reported | `{param}` vs `${expr}` normalized; `?query` dropped; test files and `include_in_schema=False` ignored; a `/webhooks` route and a `/webhooks` doc row both ignored |
| (harness) | registry missing or corrupt; run state unreadable | every command denied; phase falls to brainstorm | — |

198 cases in the engine suite and 11 in the overlay suite. All pass.

## 6. What enforces today, and the gaps

| Layer | In place | Gap |
|-------|----------|-----|
| Container | firewall (prod host, `api.brevo.com`, `admin.shopify.com`, `ghcr.io` absent by design), masks, one scoped PAT, no sudo | `.claude-devcontainer/settings.json` is agent-writable: the agent can delete its own hooks and the attribution setting |
| Claude hooks | one `PreToolUse` (Read outside the project → ask), one `PostToolUseFailure` (commit failed → notify) | both live in agent-writable files |
| Git hooks | none in any of the six repos; no pre-commit config | step 8 is empty |
| CI | backend: `ruff check` + `pytest`; app: `typecheck` + `vitest`; www: `check-legal-consistency` + hugo build | ESLint is configured but not in CI; pyright is configured but not in CI |
| Server side | the `production` push triggers the release workflow, which runs CI as its gate | **no branch protection**: the API answers "Upgrade to GitHub Pro or make this repository public". The release workflow's own comment says the same. CHECKLIST item "Deploy approval gates (#12)" is unchecked. A red CI does not block a merge to main; it blocks the release. |
| Scripts with exit codes | `check-tickets`, `check-legal-consistency.py`, `translate.py check`, `check-grammar.py` | the pattern exists; it is not applied to most rules |

The server-side gap changes the plan. On this plan tier, the only
server-side control is what the workflows themselves refuse. That makes
two things more important than the general plan assumed: the managed
settings in the image (plan P0), and checks inside `ci.yml` and the
release workflow (§7).

## 7. Recommendations for the owner

1. **P0 — done.** `template/managed-settings.json` is in the image
   with `allowManagedHooksOnly`, `disableBypassPermissionsMode`,
   `disableSideloadFlags`, the `attribution` block and the harness
   hooks; `entry.sh` creates `/run/harness`; `dcc approve` runs
   `harness approve` as root. `allowManagedPermissionRulesOnly` was left
   out on purpose ([safety-harness.md](safety-harness.md) §14).
2. **Let the release workflow refuse a direct push.** In
   `extracarts-deployment/.github/workflows/deploy.yml`, before the tag
   step: fail unless `git log -1 --format=%P` has two parents and the
   subject starts with `Merge pull request` or `Release:`. That gives
   `no-production-push` a server-side guarantee without branch
   protection.
3. **Add a `no-session-links` job to both `ci.yml` files.** Grep the PR
   body (`github.event.pull_request.body`) and `git log --format=%B
   base..head` for the same regex the hook uses. CI gates the release, so
   a link cannot reach production; it can still reach main. State that
   limit.
4. **Call `sub-issues-native` and `status-follows-pr` from
   `bin/check-tickets`**, or run `harness check`. Both checkers exist and
   follow the same findings-and-exit-1 shape.
5. **Fix the contract drift the coverage check found** on the first run
   against the live workspace: `API.md` lacks rows for
   `POST /v1/orders/backfill/release` and `POST /v1/shops/emails/hold`
   (both called by the app today) and `GET /v1/shops/activity/{event_id}`.
   The webhooks are out of scope by decision (2026-08-24): they are
   Shopify's and Brevo's contract, so `/webhooks` is excluded from all
   three sources, as `/admin` is. Also rewrite the AGENTS.md line: there is no second copy; the
   contract is `API.md` plus the app's `/v1` literals, and the check
   compares the three.
6. **Decide the `production` environment reviewer** (CHECKLIST #12). It is
   the one server-side human gate available on this plan tier.
7. **Read-only mounts for the protected paths** in `devcontainer.json`:
   `static/legal/`, the archive pages, `docs/design-mockup/`. Then the
   `pre-write` hook is feedback and the mount is the guarantee.

## 8. Order of work

| Phase | Work | Rules covered |
|-------|------|---------------|
| 1 | **done** — P0 managed settings + the hooks + `harness` CLI + `dcc approve`/`approve-release`, in the image | all 14 enforce, every checker |
| 2 | Release workflow refusal + CI session-link job | `no-production-push`, `no-session-links` get a server-side guarantee |
| 3 | done here: ten checkers, the post-write and stop dispatchers, `harness check`, the release token, the approval scope | 10 verify rules, `release-ships-tip`, `scope-to-project` |
| 4 | Fix the contract drift; wire `de-en-parity`; a LanguageTool sidecar or host step for `grammar-gate` | the three that need the owner |
| 5 | Read-only mounts for the protected paths; the run certificate (plan P4) | the guarantee behind `pre-write` |

Phase 1 covers every incident in §5. That is the argument for doing it
first.
