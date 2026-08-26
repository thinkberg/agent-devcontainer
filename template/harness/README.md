# harness/ — the engine and the generic rules

Installed into the image at `/usr/local/lib/harness` by the Dockerfile,
root-owned; `harness` is on the PATH. Wired by `managed-settings.json` for
Claude Code and `codex-requirements.toml` for Codex, which the agent cannot
change either.

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

Two differences matter when you write a rule, because the same hook
serves both agents:

- Codex edits files with one tool, `apply_patch`, whose `tool_input` is a
  patch text and not a `file_path`. The engine reads the target paths out
  of the patch, so `paths` and `protected_paths` work unchanged — but a
  rule that reads `tool_input.file_path` itself will see nothing.
- Codex calls `PostToolUse` after a **failed** shell command as well, and
  its `tool_response` for a shell tool is the raw output text with no exit
  status. A rule cannot tell a passing command from a failing one there.

The worked example — a real project's rules classified and overlaid —
is [docs/rules-extracarts.md](../../docs/rules-extracarts.md); that overlay
lives in the extracarts project, not here. A step-by-step guide in
Simplified Technical English, with operator and agent procedures kept
apart, is [docs/harness-ste.md](../../docs/harness-ste.md).

| File | Purpose |
|------|---------|
| `rules.json` | The generic registry: 22 rules (git hygiene, publish surface, secrets, the phase machine, protected policy paths, the ticket workflow) and the default `phases`. |
| `harness.py` | The engine, one program (Python, standard library only). `hook pre-bash`: PreToolUse `Bash` — regex rules, the `-C /abs` builtin, checker-backed rules (`when` + `run`); first match denies. `hook pre-write`: PreToolUse `Edit\|Write\|…\|Bash` — protected paths, then the phase gate and the approved scope. `hook post-write`: PostToolUse — the checkers whose `paths` match the edited file; findings go back to the agent. `hook stop-checks`: Stop — the `stop` checkers; `block` rules block once per session, `warn` rules become a system message. `hook ticket-state post\|stop`: a session that changed tickets cannot end until `bin/check-tickets` ran clean. CLI: `status`; `steps` (the process, current phase marked); `rules [--step] [--json]`; `phase …` with mechanical preconditions; `approve <plan> [--scope g…]` and `approve-release <repo> <pr>` (operator, via `dcc` on the host); `check [--base REF]` — the gate's dry run; a per-file rule (`{file}` in its template) runs over every workspace file its `paths` match. |
| `checkers/` | Eight generic checkers under one exit-code contract (`checkers/README.md`): spec headings, review ticks, hugo build, checklist upkeep, dangling hotfixes, version re-pin, release approval, and — optional, needs `ste100` — ASD-STE100 compliance of markdown (wiring: [docs/harness-ste.md](../../docs/harness-ste.md), D.8). A project wires them with its paths, or adds its own. |
| `tests/run.sh` | 204 positive, negative, bypass, fail-closed and overlay-merge cases on a made-up workspace (`tests/fixtures/project.json` is the fixture overlay; `tests/checks.sh` holds the checker ones; `tests/fake-gh` and `tests/fake-ste100` answer `gh` and `ste100` offline). |

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
registry denies; no run state means brainstorm. The hooks fail closed —
also on a rule regex that does not compile, and on a bug in the engine
itself (a PreToolUse hook then denies instead of erroring out, which
would allow). Regexes are Python `re`, matched line by line like
`grep -E`: `\b \s \S` work, POSIX classes (`[[:space:]]`) do not.
The hook path spawns no program: the phase gate hashes the plan file
itself (`hashlib`, the same id as git's blob); `git` runs only in the
CLI verbs that assert "committed", checkers only when a rule binds.
The interpreter runs with `-I` (see the shebang): no user site-packages
and no `PYTHON*` variables, so nothing the agent can write runs inside a
hook.

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
