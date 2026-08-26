# The harness (ASD-STE100)

This document tells you how the harness in `template/harness/` operates
and which tasks you do. The document uses the rules of ASD-STE100. The
technical names and technical verbs of this project are in
[`ste-glossary.yaml`](ste-glossary.yaml).

The document has two types of sections:

- **Description** sections tell you how the harness operates. You read
  these sections.
- **Procedure** sections give the steps that you do. Each step is one
  task. Procedures for the **operator** (a person, on the host) and
  procedures for the **agent** (Claude Code, in the container) are in
  different sections.

Applicable documents: the source README
[`template/harness/README.md`](../template/harness/README.md), the
harness plan [`safety-harness.md`](safety-harness.md), and a full
project example [`rules-extracarts.md`](rules-extracarts.md).

---

## Part A — Description: the harness

### A.1 The harness

The harness is a set of programs. The harness makes a decision on each
tool call of the agent. The agent gives the tool call. The harness
accepts or denies the tool call. The agent cannot edit the harness.

The harness has four parts:

| Part | Function |
|------|----------|
| Hooks | Programs that Claude Code runs before a tool call, after a tool call, and at the end of a session. |
| CLI `harness` | The command that shows and changes the run state. The agent uses the CLI. The operator uses the CLI for approvals, through `dcc`. |
| Checkers | Small programs. Each checker examines one condition in the workspace. |
| Registry `rules.json` | The list of rules and the default work procedure. |

### A.2 Locations

| Location | Function | Owner |
|----------|-------------|-------|
| `/usr/local/lib/harness` | The harness: engine, hooks, checkers, generic rules. The image build copies the harness from `.devcontainer/harness/`, a copy of `template/harness/`. | root |
| `/etc/claude-code/managed-settings.json` | The settings file that connects the hooks to Claude Code. | root |
| `<workspace>/.devcontainer/rules/` | The project overlay: the rules, paths and checkers of the project. The container mounts the overlay with write protection. | the operator |
| `$HARNESS_AGENT_DIR` (default `/run/harness/agent`) | The run state (`run.json`). | the agent |
| `$HARNESS_APPROVAL_DIR` (default `/run/harness/approvals`) | The approval tokens. | root |
| `$HARNESS_OFF` (default `/run/harness/off`) | The off switch. When this file is there, the hooks make no decisions. | root |

The `harness` command is on the PATH.

After each container start, `/run` is empty. Approvals do not stay after
a restart. After a restart, the harness is always on.

The guarantee is applicable only in the container. When the harness runs
on the host, the agent can write the default paths. The tests use test
directories for these paths.

### A.3 The files

| File | Function |
|------|----------|
| `rules.json` | The generic registry: 22 rules and the default work procedure (`phases`). The rules are about git, the publish step, secrets, the phases, the protected paths and the tickets. |
| `harness.py` | The engine. One Python program, standard library only. It contains the hooks and the CLI. |
| `harness.py hook pre-bash` | Runs before each `Bash` call. Applies the regex rules, the `-C /abs` builtin rule and the checker rules (`when` + `run`). The first rule that matches denies the call. |
| `harness.py hook pre-write` | Runs before each `Edit`, `Write` or `Bash` call that writes a file. Applies the protected paths first. Then applies the phase gate and the approved scope. |
| `harness.py hook post-write` | Runs after an edit. Runs the checkers with a `paths` entry that matches the edited file. Sends the findings to the agent. |
| `harness.py hook stop-checks` | Runs when the session stops. Runs the `stop` checkers. A `block` rule blocks the session end one time in each session. A `warn` rule becomes a system message. |
| `harness.py hook ticket-state` | Runs after a `Bash` call and at the session end. If the session changed tickets, the session cannot stop until `bin/check-tickets` ran without findings. |
| `harness.py status` and the other verbs | The CLI. Refer to A.7. |
| `checkers/` | Eight generic checkers. Refer to A.6. |
| `tests/run.sh` | 201 tests on a test workspace. |

### A.4 The hook contract

- A hook reads JSON from stdin.
- A hook writes a JSON decision to stdout and exits with code 0.
- No output is no decision.
- A Stop hook blocks with exit code 2.
- If a hook cannot read the registry, the hook denies.
- If there is no run state, the phase is `brainstorm`.
- If the overlay is corrupt, all hooks deny.

In a failure, a hook denies. A failure does not let a call through.

### A.5 The rules

A rule has an `id`, a `step`, a `class`, a `text` and, in most rules, a
`check`.

The `step` is the step of the work that the rule is applicable to. The
steps are: `intake`, `plan`, `implement`, `verify`, `commit`, `publish`,
`release`, `close`, `ops`.

The `class` tells how the harness uses the rule:

| Class | Effect |
|-------|--------|
| `enforce` | A hook denies the call when the check finds a violation. |
| `verify` | A checker examines the workspace. The findings go to the agent, or the findings block the session end. |
| `approve` | A decision of a person is necessary. The check looks for an approval token. |
| `advise` | Text only. No hook runs. The agent reads the text with `harness rules`. |

The `check` tells how the harness examines the rule:

| Key | Effect |
|-----|--------|
| `builtin` | A test in the hook code, for example `phase-gate`. |
| `regex` | One or more patterns. The hook denies a `Bash` command that matches. |
| `when` + `run` | If `when` matches the `Bash` command, the hook runs the checker in `run`. |
| `paths` + `run` | If `paths` matches the edited file, the hook runs the checker in `run`. |
| `dirty_on` | A `Bash` command that matches sets the session to dirty. Refer to `ticket-state.sh`. |

A rule with a checker also has a `trigger`: `pre_bash`, `post_write`,
`stop` or `gate`, or a list of triggers. `harness check` runs the `gate`
rules. The hooks run the other triggers. A `stop` rule can have
`enforcement: block` or `enforcement: warn`. The default is `warn`.

### A.6 The checkers

A checker is a program. The hook gives the target as arguments. The hook
gives the hook input as JSON on stdin. The checker prints one finding on
each line. The exit code gives the result:

| Exit code | Result |
|-----------|--------|
| 0 | No violation. |
| 1 | Violation. The findings tell the cause. |
| 2 | Approval necessary. A decision of a person is missing. |
| 3 or more | Error. The check could not run. The harness counts this result as a violation. |

A checker does not edit the workspace. A build checker renders into a
work directory.

A rule gives the checker in `check.run`. The template accepts these
placeholders:

| Placeholder | Value |
|-------------|-------|
| `{checkers}` | The directory of the generic checkers. |
| `{project}` | The directory of the project overlay (`.devcontainer/rules/`). |
| `{root}` | The workspace root. |
| `{file}` | The edited file. The path starts at the root. In `harness check`, each workspace file that matches `check.paths`, one run for each file. |
| `{repo}` | The first path part of `{file}`. |

A checker that has a configuration reads the configuration from the
merged registry. The file name is in `HARNESS_RULES`.

The generic checkers are: `spec-section-stability`,
`review-tick-has-date`, `hugo-warning-clean`, `checklist-upkeep`,
`hotfix-must-land`, `versions-repin`, `release-approved` and
`ste-compliant` (refer to D.8). A generic
checker is not active until the project overlay connects the checker to
the project paths.

### A.7 The `harness` command

| Command | Who | Effect |
|---------|-----|--------|
| `harness status` | agent | Shows the harness switch, the number of rules, the phase, the ticket, the plan and the approval state. |
| `harness steps` | agent | Shows the work procedure with a mark on the phase of the run. |
| `harness rules [--step <name>]` | agent | Shows the rules. With `--step`, shows the rules of one step. |
| `harness phase <name> [--ticket <repo>#<n>] [--plan <path>] [--ponytail-reviewed]` | agent | Moves the run to a phase. The command examines the precondition of the phase. If the precondition is not satisfactory, the command exits with code 1 and tells the cause. |
| `harness check [--base REF]` | agent; operator with `dcc check` | Runs the `gate` checkers. A rule with `{file}` in `check.run` runs once for each workspace file that matches `check.paths`. Shows the result of each rule. |
| `harness approve <plan> [--scope <glob>…]` | operator with `dcc approve` | Writes an approval token for a committed plan. |
| `harness approve-release <repo> <pr>` | operator with `dcc approve-release` | Writes an approval token for a Release PR at the PR head. |

### A.8 The work procedure (phases)

The work procedure has four phases in sequence:

```
brainstorm → plan → review → implement
```

| Phase | Permitted writes | Precondition |
|-------|------------------|--------------|
| `brainstorm` | `*.md` | None. Without run state, the run is in this phase. |
| `plan` | `*.md` | A ticket that matches `ticket_regex`. |
| `review` | `*.md` | The plan file is in `plan_glob`. The plan has a commit and no edits after the commit. The agent gave `--ponytail-reviewed`. |
| `implement` | `*`, or the approved scope | An approval token. The token holds the committed blob hash of the plan. |

The paths in `always_allow` (for example `/tmp/*` and the memory
directory) are writable in all phases.

In `implement`, the agent can write the approved scope and the paths of
the `review` phase. Thus the plan markdown stays writable.

The **effective phase** is the phase that the hooks apply. The effective
phase is the declared phase, with one exception. If the phase is
`implement` and the token does not agree with the committed plan, the
effective phase is `review`. Thus, after a plan edit, the run goes back to
`review`.

After `implement`, the steps `verify`, `commit`, `publish`, `release`
and `close` are not phases. Rules apply to these steps.

### A.9 The project overlay

The project overlay is `<workspace>/.devcontainer/rules/rules.json`.
`dcc init` makes the overlay from the template. The engine merges the
overlay into the generic registry when a hook starts.

| Overlay key | Effect |
|-------------|--------|
| `project` | The block of the project, for example the name. Project checkers read this block. |
| `rules` | The engine adds these rules to the registry. A rule with the same `id` as a generic rule replaces the generic rule. |
| `disabled` | A list of generic rule ids. The engine removes these rules. |
| `protected_paths` | The engine adds these paths to the list of protected paths. |
| `phases` | The keys replace the default work procedure: `plan_glob`, `ticket_regex`, `allow_write`. |
| `checkers/` | A directory adjacent to `rules.json`. A rule refers to a project checker as `{project}/checkers/<name>`. |

A corrupt overlay causes all hooks to deny. A project without an overlay
is permitted. The generic registry operates without an overlay.

### A.10 The guarantee and its limits

The hooks are the inner loop. The hooks give the agent fast information
with the rule `id`.

The hooks are not the guarantee. The guarantee of a rule is the control
at the step that does, publishes or accepts the change. Examples: the firewall, the mount with write protection, the missing
credential, the token directory of root, the CI gate.
`rules-extracarts.md` gives the control for each rule.

The harness does not guarantee that the agent knows a rule. A rule
without a mechanical test is an approval point for a person, or a risk
that you accept.

---

<!-- ste: procedure -->

## Part B — Procedures for the operator

The operator operates on the host with `dcc`.

### B.1 Install the harness in a project

1. Go to the project root.
2. Run `dcc init <name>`. Use only `a-z`, `0-9` and `-` in the name. `dcc init` writes the name into `project.name` of the
   overlay.
3. Run `dcc up`.

Result: The container runs with the generic rules and the overlay.

### B.2 Approve a plan

Do this procedure when the agent tells you to approve a plan. Also do
this procedure when `harness status` shows `approval: none` and a
committed plan.

1. Read the plan file.
2. Make sure that the plan has a commit. `dcc approve` does not accept an
   uncommitted plan.
3. Run `dcc approve <plan-path>`.
4. If necessary, add `--scope <glob>…`. The scope sets a limit for the
   files that the agent can write. Example:
   `dcc approve plans/2026-08-24-thing.md --scope 'backend/*'`.

Result: The harness writes the token. The agent can go to `implement`.

If the agent changes the plan after the approval, do steps 1 to 4 again.

To increase the scope, run `dcc approve` again with the new scope.

### B.3 Approve a Release PR

1. Make sure that the PR has the base branch `production`.
2. Read the commits that `main` got after the PR start. The agent gives
   this list.
3. Run `dcc approve-release <repo-dir> <pr>`.

Result: The token holds the head SHA of the PR. A new commit on the PR
makes the token stale.

### B.4 Run the gate checks

1. Run `dcc check`.
2. Read the result of each rule: `ok`, `FAIL`, `NEEDS` (approval),
   `ERROR`.

### B.5 Set the harness to off and to on

Do this procedure only when you must operate without the harness for a
short time.

1. Run `dcc harness off`. The hooks make no decisions. The usual
   permission prompts of Claude Code apply.
2. Run `dcc harness on` when you complete the work.

A container restart sets the harness to on.

### B.6 Apply a rule change that the agent gave

The agent cannot write `.devcontainer/`. The agent gives a change as
text.

1. Read the change.
2. Apply the change to `.devcontainer/rules/rules.json` or `checkers/`
   on the host.
3. A restart is not necessary. The engine reads the overlay at each hook
   start.

### B.7 Run the test suite

1. Install `bash`, `jq`, `git` and `python3`.
2. Run `template/harness/tests/run.sh`.

The tests do not use the network or `hugo`. The tests use
`tests/fake-gh` and `tests/fake-ste100` and not the `gh` and `ste100`
commands.

---

## Part C — Procedures for the agent

The agent operates in the container with `harness`.

### C.1 Start a task

1. Run `harness status`. Read the phase and the approval state.
2. Run `harness steps`. Read the work procedure.
3. Run `harness rules --step <name>`. Read the rules of the step.

### C.2 Go from brainstorm to plan

1. Get the ticket. The ticket must match `ticket_regex`, for example
   `backend#12`.
2. Run `harness phase plan --ticket backend#12`.

Result: You can write markdown only.

### C.3 Write the plan and go to review

1. Write the plan file in `plan_glob`, for example
   `plans/2026-08-24-thing.md`.
2. Commit the plan. Give the file paths. Use `git -C /absolute/path`.
3. Do a ponytail review of the plan. Apply the results to the plan.
   Commit again.
4. Run `harness phase review --plan plans/2026-08-24-thing.md --ponytail-reviewed`.

If the command exits with code 1, read the message. The message tells
you which precondition is not satisfactory.

### C.4 Get the approval

1. Tell the operator to run `dcc approve <plan-path>` on the host.
2. Run `harness status` until the status shows `approval: valid`.

Do not edit the plan while you wait. A plan edit makes the approval
stale.

### C.5 Implement

1. Run `harness phase implement`.
2. Write code in the approved scope.
3. Read the findings from the `post-write` hook. Correct the findings.

If the hook denies an edit with `scope-to-project`, tell the operator to
increase the scope.

### C.6 Verify before a commit or the session end

1. Run `harness check`. Correct each `FAIL`.
2. For each `NEEDS`, tell the operator that an approval is necessary.
3. If you changed tickets, run `bin/check-tickets`. The session cannot
   stop before this command ran without findings.

### C.7 Give a rule change

You cannot write `.devcontainer/`.

1. Write the change as text: the rule JSON, or the checker program.
2. Give the text to the operator.

---

## Part D — Configure the harness for a project

All configuration is in the project overlay
`<workspace>/.devcontainer/rules/rules.json` and the `checkers/`
directory. The operator edits the overlay on the host. The generic
harness stays the same.

### D.1 Set the plan glob and the ticket regex

1. Set `phases.plan_glob` to the location of the plans. Example:
   `"planning/plans/*.md"`.
2. Set `phases.ticket_regex` to the ticket pattern. Example:
   `"^(backend|app|deploy|www)#[0-9]+$"`.
3. Set `phases.allow_write` for `brainstorm`, `plan` and `review`. Give
   the markdown that the agent can write before the approval. Example:
   `["planning/*.md", "*/docs/*.md"]`.

Do not increase `allow_write.implement`. The approval scope controls the
code writes.

### D.2 Set the protected paths

1. Add globs to `protected_paths`. Examples: `www/public/*`,
   `www/static/legal/*.pdf`, `www/content/*/*-v[0-9]*.md`.

The agent cannot write these paths in all phases.

### D.3 Connect a generic checker

1. Add a rule to `rules`. Set `class` to `verify`.
2. Set `trigger`. Use `post_write` for a check after each edit. Use
   `stop` for the session end. Use `gate` for `harness check`. Use
   `pre_bash` for a check before a command.
3. For `post_write`, set `check.paths` to the files that cause the check.
   A `gate` rule with `{file}` in `check.run` also needs `check.paths`:
   `harness check` runs the checker for each file that matches.
4. For `pre_bash`, set `check.when` to the command pattern.
5. Set `check.run` to the checker and the target. Example:
   `"{checkers}/hugo-warning-clean {root}/www"`.
6. For a `stop` rule, set `enforcement` to `block` or `warn`. The default
   is `warn`.

Example: a rule that runs the Hugo build check after an edit of the site
configuration.

```json
{
  "id": "hugo-warning-clean",
  "class": "verify",
  "step": "verify",
  "trigger": "post_write",
  "text": "The site build is warning-clean.",
  "check": {
    "paths": ["www/hugo.toml", "www/layouts/*"],
    "run": "{checkers}/hugo-warning-clean {root}/www"
  }
}
```

### D.4 Write a project checker

1. Write a program in `.devcontainer/rules/checkers/<name>`. Make the
   program executable.
2. Read the target from the arguments. Read the hook input from stdin
   when the hook gives input.
3. Print one finding on each line.
4. Exit with code 0, 1, 2 or 3+. Refer to A.6.
5. Do not edit the workspace.
6. If the checker has a configuration, put the configuration in the rule
   or in `project`. Read the file that `HARNESS_RULES` gives.
7. Refer to the checker in a rule as
   `"{project}/checkers/<name> {root}/<target>"`.

### D.5 Add a deny rule for a command

1. Add a rule with `class: "enforce"` and `check.regex` with one or more
   patterns.
2. Do a test of the pattern with the commands that the rule must deny.
   Do a test with the commands that the rule must let through.

Example: the generic rule `git-no-bypass` denies `--no-verify` and
`--no-gpg-sign`.

### D.6 Replace or remove a generic rule

- To replace a rule: add a rule with the same `id`. The engine uses the
  overlay rule.
- To remove a rule: add the `id` to `disabled`.

Remove a rule only when a different control has the same effect.

### D.7 Do a test of the overlay

1. Run `dcc check` in the container. A corrupt overlay causes all hooks
   to deny. Then `harness status` tells you that the hook cannot read the
   registry.
2. Make a small edit in `allow_write`. Make sure that the hook accepts
   this edit.
3. Make a small edit out of `allow_write`. Make sure that the hook
   denies this edit.
4. For a new checker, make one violation. Make sure that the hook shows
   the finding.

The fixture overlay
[`template/harness/tests/fixtures/project.json`](../template/harness/tests/fixtures/project.json)
uses all overlay functions. Use the fixture as an example.

### D.8 Check documents with ASD-STE100 (optional)

The checker `ste-compliant` examines markdown files with the ASD-STE100
rules. The checker uses the `ste100` command from
[`asd-ste100-checker`](https://github.com/sourdough-bread/asd-ste100-checker).
Without `ste100`, the checker exits with code 3.

1. Install `ste100` in the container:
   `pip install git+https://github.com/sourdough-bread/asd-ste100-checker`,
   then `ste100 setup`.
2. Put the technical names and technical verbs of the project in a
   glossary file. Use [`ste-glossary.yaml`](ste-glossary.yaml) as an
   example.
3. Put `<!-- ste: procedure -->` before the procedures in a document. Put
   `<!-- ste: description -->` before the descriptions. Text without a
   marker is a description.
4. Add a rule to the overlay:

```json
{
  "id": "ste-compliant",
  "class": "verify",
  "step": "verify",
  "trigger": ["post_write", "gate"],
  "text": "Documents follow ASD-STE100.",
  "check": {
    "paths": ["docs/*.md"],
    "run": "{checkers}/ste-compliant --glossary {root}/docs/ste-glossary.yaml {root}/docs"
  }
}
```

Result: After each edit of a document, the hook shows the STE errors. The
checker does not show warnings. The checker ignores `STE-POS-MISMATCH`
and `STE-TOPIC-SENTENCE`, because the checker tags some approved words
with the wrong part of speech. Use `--ignore ''` to see all findings.
