# harness/ — the engine and the generic rules

Installed into the image at `/usr/local/lib/harness` by the Dockerfile,
root-owned; `harness` is on the PATH. Wired by `managed-settings.json`
(`/etc/claude-code/`), which the agent cannot change either.

The deterministic harness: hooks, a CLI, checkers, and the generic rule
registry with the default working process. Nothing project-specific
lives here. A project adds its own rules, paths and checkers in
`<workspace>/.devcontainer/rules/` — an overlay that `dcc init` seeds
from [`template/harness/`](../template/harness/) and that the engine
merges over the generic registry at load time:

| Overlay key | Effect |
|-------------|--------|
| `rules` | added; a rule with a generic id replaces the generic one |
| `disabled` | generic rule ids removed |
| `protected_paths` | appended to the read-only list |
| `phases` | keys override the default working process (`plan_glob`, `ticket_regex`, `allow_write`) |
| `project` | the project's own block, read by its checkers |
| `checkers/` | project checkers, addressed as `{project}/checkers/<name>` |

A corrupt overlay fails closed: every hook denies. No overlay at all is
fine: the generic registry works alone.

The worked example — a real project's rules classified and overlaid —
is [docs/rules-extracarts.md](../../docs/rules-extracarts.md); that overlay
lives in the extracarts project, not here. A step-by-step guide in
Simplified Technical English, with operator and agent procedures kept
apart, is [docs/harness-ste.md](../../docs/harness-ste.md).

| File | Purpose |
|------|---------|
| `rules.json` | The generic registry: 22 rules (git hygiene, publish surface, secrets, the phase machine, protected policy paths, the ticket workflow) and the default `phases`. |
| `lib.sh`, `dispatch.sh` | Shared: plan blob hash, effective phase, approval token and scope; running a checker by its `run` template. |
| `bin/harness` | `status`; `steps` (the process, current phase marked); `rules [--step]`; `phase …` with mechanical preconditions; `approve <plan> [--scope g…]` and `approve-release <repo> <pr>` (operator, via `dcc` on the host); `check [--base REF]` — the gate's dry run. |
| `hooks/pre-bash.sh` | PreToolUse `Bash`. Regex rules, the `-C /abs` builtin, and checker-backed rules (`when` + `run`). First match denies. |
| `hooks/pre-write.sh` | PreToolUse `Edit\|Write\|…\|Bash`. Protected paths, then the phase gate and the approved scope. |
| `hooks/post-write.sh` | PostToolUse. Runs the checkers whose `paths` match the edited file; findings go back to the agent. |
| `hooks/stop-checks.sh` | Stop. Runs the `stop` checkers: `block` rules block once per session, `warn` rules become a system message. |
| `hooks/ticket-state.sh` | PostToolUse + Stop. A session that changed tickets cannot end until `bin/check-tickets` ran clean. |
| `checkers/` | Eight generic checkers under one exit-code contract (`checkers/README.md`): spec headings, review ticks, hugo build, checklist upkeep, dangling hotfixes, version re-pin, release approval, and — optional, needs `ste100` — ASD-STE100 compliance of markdown (wiring: [docs/harness-ste.md](../../docs/harness-ste.md), D.8). A project wires them with its paths, or adds its own. |
| `tests/run.sh` | 198 positive, negative, bypass, fail-closed and overlay-merge cases on a made-up workspace (`tests/fixtures/project.json` is the fixture overlay; `tests/checks.sh` holds the checker ones; `tests/fake-gh` and `tests/fake-ste100` answer `gh` and `ste100` offline). |

```bash
harness/tests/run.sh          # needs bash, jq, git, python3; no network, no hugo, no real gh
```

The working process, as the agent sees it:

```bash
harness status
harness phase plan --ticket backend#12
# write plans/2026-08-24-thing.md, commit it, ponytail-review it
harness phase review --plan plans/2026-08-24-thing.md --ponytail-reviewed
# the operator, on the host:   dcc approve plans/2026-08-24-thing.md --scope 'backend/*'
harness phase implement
harness check                 # what the gate will ask, on demand
```

Contract of a hook: JSON on stdin, JSON decision on stdout, exit 0. No
output means no decision. A Stop hook blocks with exit 2. An unreadable
registry denies; no run state means brainstorm. The hooks fail closed.

State: `$HARNESS_AGENT_DIR` (default `/run/harness/agent`, agent-writable)
holds the run state; `$HARNESS_APPROVAL_DIR` (default
`/run/harness/approvals`, root-only in the container) holds the tokens;
`$HARNESS_OFF` (default `/run/harness/off`, root-only) is the operator's
switch — present means every hook exits without a decision.
Outside the container both default to paths the agent could write —
the tests set them to temp dirs. The guarantee needs the container.

These hooks are the inner loop. They give the agent fast, named feedback.
The guarantee for each rule is the control at the execute, publish or
accept step (firewall, read-only mount, credential absence, root-owned
token directory, CI gate); `docs/rules-extracarts.md` names it per rule.
