# Plan: a safety harness for the agent devcontainer

Status: plan, partly built. P0, P3 and the registry and CLI of P1 are
done (§14). Sections 2 and 3 describe the state before P0. The built
engine is documented in [harness-ste.md](harness-ste.md); this document
keeps the design and the open phases.

This document uses the rules of
[Simplified Technical English](https://en.wikipedia.org/wiki/Simplified_Technical_English).

## 1. The guarantee

An agent reads rules in natural language. It can forget a rule, apply it
one time and not the next, or think that it obeyed a rule when it did
not. More text does not correct this. Reviewer agents and self-checks
make it better, but they do not make it certain.

The harness therefore changes what a rule is:

> The agent proposes. Conventional software decides.

The container can then give one true guarantee:

> Every side effect that an approved formal rule covers goes through a
> control. The control blocks the action if the rule fails. The agent
> cannot change or bypass the control from inside the container.

The harness does not guarantee that the agent understood a rule. A rule
that has no mechanical test stays a human approval point, or a risk that
you accept on purpose.

## 2. What the container gives today

The template already contains a part of the harness. It is the outer
boundary.

| Control | Mechanism | Can the agent bypass it? |
|---------|-----------|--------------------------|
| Egress | ipset + iptables, default DROP, built by pid 1 as root | No. `vscode` has no capabilities and no sudo. |
| Secrets in files | Read-only bind mounts of an empty file or directory | No. Remount needs `CAP_SYS_ADMIN`. |
| Credentials | One fine-grained PAT, no Workflows permission | It has the token. It cannot widen the token. |
| Dangerous merges and deploys | Branch protection on the forge | No. The forge decides. |
| Egress grants | `dcc allow`, run on the **host** | No. Approval is outside the container. |

Two design decisions in this repository are the base of everything
below:

- Root work happens as pid 1, or through `podman exec -u root` from the
  host. The agent is `vscode` and has no path to root.
- Approval lives on the host. `dcc allow` is the model for every other
  approval.

## 3. What is missing

The boundary controls *where* the agent can go. It does not control
*what* the agent does inside, and it does not control *how work leaves*
the workspace.

| Gap | Effect |
|-----|--------|
| No machine-readable rules | Every rule is prose. Nothing can test it. |
| No task contract | The scope of a run is an idea, not a value. |
| No pre-action control | A forbidden edit or command runs, then you find it. |
| Agent-writable agent state | `.claude-devcontainer` and `.codex-devcontainer` are mounted read-write. The agent can edit its own settings and hooks. |
| No completion gate | The agent declares that it is done. Nothing tests the claim. |
| Push is unmediated | The agent holds the PAT. It can push at any time. |
| No tests for the rules | Nobody knows if a rule still blocks what it must block. |

## 4. Architecture

Three layers. Each layer has a different strength. Do not mix them.

| Layer | Contains | Gives |
|-------|----------|-------|
| 1. Prompt | Short CLAUDE.md, a rule digest, reminders before critical actions | Better behavior. No guarantee. |
| 2. Policy | Firewall, masks, capabilities, managed settings, hooks, approval tokens | Prevention of named side effects. |
| 3. Evidence | Independent checkers, the gate, the run certificate, CI, branch protection | The decision to accept the work. |

The rules for all three layers come from **one** source: the rule
registry. Layer 1 renders the registry as text. Layer 2 compiles it into
controls. Layer 3 tests the result against it. Prose and enforcement
cannot drift apart, because they have the same parent.

## 5. Rules applied at each step of the workflow

This is the centre of the plan. One rule can act at more than one step.
Each step has a different mechanism and a different strength.

| Step | Mechanism | Tamper-proof? | Failure mode |
|------|-----------|---------------|--------------|
| 0. Build the image | Rules and checkers are copied into the image. A rebuild is a host act. | Yes | Build fails |
| 1. Container start | `entry.sh` starts the firewall, then creates `/run/harness` as root | Yes | Container stops |
| 2. Session start | `policyHelper` compiles the registry and the contract into managed settings | Yes | Claude Code does not start |
| 3. Prompt | SessionStart hook adds the rule digest to the context | No | Text is missing |
| 4. Before a tool call | PreToolUse hook: path scope, command class, dependency change, approval token | Partly | Tool call is blocked |
| 5. Execution | Firewall, masks, file permissions, no credentials for production | Yes | The action is impossible |
| 6. After a tool call | PostToolUse hook: lint or checker on the changed file | Partly | The agent gets the error |
| 7. Completion | Stop hook: the run must be in a valid state | Partly | The agent cannot stop |
| 8. Commit | `core.hooksPath` to a root-owned hook | No (`--no-verify`) | The commit is refused |
| 9. Publish | The gate on the **host**, then the push | Yes | No push happens |
| 10. Accept | CI, required checks, branch protection | Yes | No merge happens |

Read the "Tamper-proof?" column carefully. Steps 4, 6, 7 and 8 are the
inner loop. They give fast feedback. The Claude Code documentation says
that hooks are not a complete security boundary. Steps 0, 1, 2, 5, 9 and
10 are the outer boundary. They hold even if the inner loop fails.

**A rule that matters must have a control at step 5, 9 or 10. A control
at step 4 alone is help, not a guarantee.**

Step 10 needs care. Branch protection is not available on every GitHub
plan tier (private repositories on a free organization plan have none;
the extracarts repositories are in that state). Then the only server-side
control is what the workflows refuse themselves: a release workflow that
fails on a non-merge commit, a CI job that fails on a forbidden pattern.
The plan must say which case applies.

## 6. Why managed settings are strong in this container

Claude Code reads settings in this order. The first level wins:

1. Managed settings (`/etc/claude-code/managed-settings.json` and
   `/etc/claude-code/managed-settings.d/*.json` on Linux)
2. `claude --settings`
3. `.claude/settings.local.json`
4. `.claude/settings.json`
5. `~/.claude/settings.json`

On a normal workstation this is weak. The documentation says it: a
developer with local admin rights can edit the managed file itself.

This container removes exactly that escape. The managed file is in the
image. It belongs to root. `vscode` has no capabilities, `sudo` is
inert, and `no-new-privileges` kills setuid. Only a host-side rebuild
changes the file — the same act as a change to `allowlist.txt`.

**In this container, managed settings become a real control instead of a
policy.** These keys matter most:

| Key | Effect |
|-----|--------|
| `permissions.deny` | Deny reads, writes and commands by pattern |
| `allowManagedPermissionRulesOnly: true` | Ignore permission rules from user, project and `--allowedTools` |
| `permissions.disableBypassPermissionsMode: "disable"` | No `--dangerously-skip-permissions` |
| `allowManagedHooksOnly: true` | Only the harness hooks run. The agent cannot add or remove hooks. Also narrows `statusLine`, `subagentStatusLine` and `fileSuggestion` to managed settings — the managed file delegates `statusLine` to `~/.claude/statusline-command.sh`. |
| `strictPluginOnlyCustomization` | No skills, agents, hooks or MCP servers from user and project files |
| `allowManagedMcpServersOnly`, `allowedMcpServers` | Only the MCP servers the harness names |
| `disableSideloadFlags: true` | Reject `--plugin-dir`, `--plugin-url`, `--agents`, `--mcp-config` |
| `policyHelper` | An executable computes the managed settings at start. If it fails, Claude Code does not start. |

`allowManagedHooksOnly` closes the largest hole in the template today.
`.claude-devcontainer` is a read-write mount. Without that key, the
agent can delete its own hooks from `~/.claude/settings.json`.

### Codex: `/etc/codex/requirements.toml`

Codex reads a root-owned requirements file with the same standing:
`.codex-devcontainer` is a read-write mount for the same reason, and the
requirements file is the key that makes that safe. It is in the image,
it belongs to root, and only a host-side rebuild changes it.

| Key | Effect |
|-----|--------|
| `allow_managed_hooks_only = true` | Only the harness hooks run. Hooks from user, project, session and plugin sources are skipped. |
| `allowed_approval_policies = ["never"]` | The container is the sandbox; no prompt path is offered. |
| `allowed_sandbox_modes` | The permitted `-s` values. **Must include `read-only`**, or Codex refuses to start at all — `login` included. |
| `[features] hooks = true` | Hooks on. `apps`, `plugins` and `computer_use` are off. |
| `[mcp_servers]` (empty table) | An explicit empty allowlist. A server the agent configures is loaded as `disabled: requirements`. |
| `[hooks] managed_dir` | Where the managed hook programs live: `/usr/local/lib/harness`. |
| `check_for_update_on_startup = false` | The image pins the version. |

Measured against `codex-cli 0.149.1` in the container. Each attempt tried
to write a `.py` file that the phase gate must deny; the harness message
in the transcript proves the managed hook ran, rather than Codex having
failed for some other reason.

| Attempt | Result |
|---------|--------|
| no flag (baseline) | denied by `phase-gate` |
| `--dangerously-bypass-hook-trust` | denied |
| `--dangerously-bypass-approvals-and-sandbox` | denied |
| `--ignore-user-config` | denied |
| `--ignore-rules` | denied |
| `--disable hooks` | denied — a managed hook is not a feature the invocation can switch off |
| `-c hooks={}`, `-c hooks.PreToolUse=[]` | denied |
| a hostile `~/.codex/config.toml` (`features.hooks = false`, its own `managed_dir`, its own PreToolUse) | denied; Codex logged `hook: PreToolUse Blocked` |
| an MCP server in that same file | `disabled: requirements (/etc/codex/requirements.toml)`; it did not run |
| the agent writing `~/.codex/config.toml` (shell redirect, `apply_patch`) | denied by `protected-paths` |
| the agent running `codex mcp add` as a shell command | **the file was written** — see §15 |

The flags read as bypasses and are not. `--dangerously-bypass-hook-trust`
makes untrusted hooks run, it does not stop the managed ones.
`--ignore-rules` is about Codex execpolicy `.rules`, not this registry.
`--ignore-user-config` skips `config.toml`, which is not where the
harness lives.

`policyHelper` is the compiler seat. It reads the registry and the
frozen contract, and it emits the managed settings for this one run. It
fails closed by design.

## 7. The rule registry

Rules live in JSON, not YAML. The image already has `jq`. This keeps the
harness free of new dependencies and in the style of the existing
scripts.

Location in the project: `.devcontainer/rules/rules.d/*.json`.
Location in the image: `/etc/harness/rules.d/*.json`, copied at build.

As built (P1): one generic `rules.json` in the image plus the project
overlay `.devcontainer/rules/rules.json`; the fields and the overlay
keys are in [harness-ste.md](harness-ste.md) A.5 and A.9. The fields
below are the design.

One rule:

```json
{
  "id": "no-dependency-change-without-approval",
  "class": "enforce",
  "scope": ["package.json", "package-lock.json", "pyproject.toml", "uv.lock"],
  "trigger": ["pre_edit", "pre_commit", "publish"],
  "predicate": "checkers/dep-change",
  "evidence": "diff of the manifest and the lock file",
  "enforcement": "require_approval",
  "failure_mode": "closed",
  "owner": "leo@thinkberg.com",
  "text": "Do not add or change a dependency without approval."
}
```

Fields:

| Field | Purpose |
|-------|---------|
| `id` | Stable name. It appears in every message and certificate. |
| `class` | `enforce`, `verify`, `approve` or `advise` |
| `scope` | Paths, command classes, services or a workflow phase |
| `trigger` | One or more steps from the table in section 5 |
| `predicate` | A checker program. Not a sentence. |
| `evidence` | What the gate must see to accept the rule as satisfied |
| `enforcement` | `allow`, `deny`, `require_approval` or `block_completion` |
| `failure_mode` | `closed` (default) or `open` |
| `owner` | The person who reads the ambiguous cases |
| `text` | The prose form. Layer 1 shows this. |

The four classes:

- `enforce` — a control blocks the violation. A guarantee.
- `verify` — a checker tests the artifact after the fact. A guarantee at
  the gate.
- `approve` — a human decides. The harness only proves that the decision
  exists.
- `advise` — prose only. No guarantee. The harness says this in the
  digest, so nobody believes more than is true.

### The checker contract

A checker is a program with an exit code: pass, violation, approval
needed, error. The built contract is
[`template/harness/checkers/README.md`](../template/harness/checkers/README.md).

Fail-closed is not optional. A checker that crashes must block, not
pass. Section 13 tests this.

### Humans approve the translation

Research says that the step from prose to a formal rule is the weak
point. The agent may draft a rule. A human must approve it.

`rules.lock` holds the SHA-256 of each rule file and the name of the
approver. The harness refuses to start if a rule file is not in the
lock. `dcc rules approve` writes the lock on the host.

The rule files in the workspace are writable by the agent, like
`allowlist.txt`. That does not matter. The image copy decides, a rebuild
is a host act, and the checker `policy-integrity` reports any difference
between the two copies.

## 8. The task contract

One run has one contract. The agent may propose it. The harness freezes
it. The agent cannot widen it.

```json
{
  "run_id": "2026-08-24T12-03-11Z-a1b2c3",
  "task": "Add a rate limit to the public API",
  "allow_write": ["src/api/**", "tests/api/**"],
  "deny_write": [".devcontainer/**", ".github/**", "docs/adr/**"],
  "allow_domains": [],
  "allow_dependency_change": false,
  "required_checks": ["lint", "typecheck", "test:api"],
  "approvals_required": ["dep-change"],
  "acceptance": "The new tests pass and no other test changes.",
  "base_sha": "c37b0eb…"
}
```

Location: `/run/harness/run/<run_id>/contract.json`. `entry.sh` creates
`/run/harness` as root, mode 0755. The agent reads it. The agent cannot
write it. `dcc contract` writes it through `podman exec -u root`, in the
same way as `dcc allow`.

The contract compiles into `permissions.deny` and into the checkers'
input. It is a value, not a paragraph.

The contract sits on top of a phase. The working process is a state
machine — brainstorm → plan → review → implement — and the transition
into implement is an approval token that only the operator can write.
The phase machine is built and tested in [`template/harness/`](../template/harness/); the
classification of a real rule corpus against it is in
[rules-extracarts.md](rules-extracarts.md). The contract adds the scope
(`allow_write`, checks, acceptance) to a run that is already in phase
implement.

To widen the contract, the agent must ask. The human runs `dcc contract
widen …` on the host. The harness records the change in the certificate.

## 9. The gate and the run certificate

The agent must not be able to say "done". Completion is a state change,
and the harness owns it.

```
RUNNING ──gate passes──► PUBLISHABLE ──push──► SUBMITTED ──CI+protection──► ACCEPTED
   ▲                                                                          │
   └──────────────────────── gate fails ◄─────────────────────────────────────┘
```

`dcc publish` runs the gate **on the host**. The gate does not trust one
byte that the agent produced. It:

1. Reads the frozen contract and the rule set from the image.
2. Makes a clean worktree at the exact commit SHA.
3. Runs every `enforce` and `verify` checker again, in that worktree.
4. Tests that the diff stays inside `allow_write`.
5. Tests that no rule file, hook, checker or CI file changed.
6. Tests that every required approval token exists and matches the SHA.
7. Writes the run certificate.
8. Only then does it push.

The certificate is the record:

```json
{
  "run_id": "…",
  "contract_sha256": "…",
  "rules_lock_sha256": "…",
  "commit": "…",
  "checkers": [{"id": "path-scope", "exit": 0}, …],
  "approvals": [{"rule": "dep-change", "by": "leo", "at": "…"}],
  "harness_version": "…",
  "image_id": "…"
}
```

Local git hooks are convenient and bypassable with `--no-verify`. They
are step 8, not the gate. The gate is step 9. CI and branch protection
are step 10, and the token has no Workflows permission, so the agent
cannot change step 10.

## 10. The push credential

The push credential stays where it is. Its scope is a separate question
and not part of this plan. The gate is `dcc gate`; it runs on the host
and writes the certificate. Whether the push after a passed gate is a
convenience command or the only path is the owner's later call.

## 11. Files to add

```
template/
  harness/
    rules.d/00-core.json         # rules that every project gets
    rules.lock                   # sha256 + approver per rule file
    bin/
      harness                    # one CLI: compile, check, gate, certify, selftest
      policy-helper              # Claude Code policyHelper; fails closed
      hook-session-start         # rule digest into the context
      hook-pre-tool              # dispatch by trigger; deny or ask
      hook-post-tool             # checker on the changed file
      hook-stop                  # block completion in an invalid state
    checkers/
      path-scope                 # writes stay inside the contract
      protected-paths            # no writes to .devcontainer, .github, harness
      policy-integrity           # workspace rules == image rules
      dep-change                 # manifest and lock diff
      required-checks            # the named checks ran on this SHA
      diff-scope                 # the diff matches the contract
    tests/                       # section 12
  managed-settings.json          # copied to /etc/claude-code/
  Dockerfile                     # COPY harness, rules, managed settings
  entry.sh                       # create /run/harness as root
docs/safety-harness.md           # this document
```

`Dockerfile` copies the harness to `/usr/local/lib/harness`, owned by
root, mode 0755. `vscode` can run it. `vscode` cannot change it.

The engine — hooks, the `harness` CLI, nine generic checkers, the
generic registry with the default working process — and its tests exist
today in [`template/harness/`](../template/harness/) and are in the
image (P0). Project-specific rules never go there: each project carries
an overlay in `.devcontainer/rules/` (seeded by `dcc init` from
`template/rules/`) that the engine merges over the generic registry.

## 12. New `dcc` commands

The host is the approval seat. Every new command follows the shape of
`dcc allow`.

| Command | Function |
|---------|----------|
| `dcc contract <file>` | Freeze the task contract for the next run |
| `dcc contract widen <path…>` | Widen the scope. It goes into the certificate. |
| `dcc approve <plan>` | **built** — approve a plan: write the token that lets the run enter phase implement |
| `dcc approve-release <repo> <pr>` | **built** — approve the merge of a Release PR at its current head |
| `dcc check` | **built** — run the gate checkers inside the container (`harness check`) |
| `dcc gate` | Run the gate. Show the certificate. Do not push. |
| `dcc publish` | Gate, then push with the host credential |
| `dcc rules approve` | Write `rules.lock` after you read the change |
| `dcc harness test` | Run the policy tests of section 13 |
| `dcc harness on\|off` | The operator's runtime switch (built): off = no decisions until on or the next start; root-owned marker, visible to the agent, not writable by it |

## 13. Test the policy system

An untested control is a belief. Every `enforce` and `verify` rule needs
four tests:

| Test | Question |
|------|----------|
| Positive | Does permitted work still pass? |
| Negative | Does the direct violation get blocked? |
| Bypass | Does a different route to the same effect also get blocked? |
| Fail closed | Does a crash or a timeout in the checker block, and not pass? |

The bypass test is the important one. A deny list of commands is not a
control. `rm`, `python -c`, `perl -e` and a small binary all delete a
file. The control must sit on the resource: the file system, the
network, the credential, the forge.

Red-team cases to keep in the suite:

1. Edit a rule file in the workspace and run again.
2. Delete the hooks from `~/.claude/settings.json`.
3. Start `claude` with `--settings`, `--agents` or `--mcp-config`.
4. Push with `git push` and with `gh`, without the gate.
5. Commit with `--no-verify`.
6. Read a masked secret through a symbolic link.
7. Reach a domain that is not on the allowlist, with `curl` and with
   `python`.
8. Write an approval token by hand.
9. Call a checker directly and use its output as evidence.
10. Make a checker time out.

Run the suite after every change to the rules, the hooks, the image or
the agent version. Keep every real violation that you see in production
as a new case.

## 14. Order of work

Each phase is useful alone. Stop after any phase.

| Phase | Work | Gives |
|-------|------|-------|
| P0 | **done** — `template/managed-settings.json` in the image: `allowManagedHooksOnly`, `disableBypassPermissionsMode`, `disableSideloadFlags`, `attribution` off, the harness hooks, deny rules on the policy paths; the engine at `/usr/local/lib/harness`; `.devcontainer` mounted read-only; `dcc approve`, `dcc approve-release`, `dcc check`. Left out on purpose: `allowManagedPermissionRulesOnly` (it would discard the operator's own allow lists and prompt for everything; the hooks deny regardless of allow rules) and `strictPluginOnlyCustomization` (it would block the project's MCP servers and skills). | The agent can no longer change its own controls. |
| P1 | Rule registry and the `harness` CLI **done**; `rules.lock` and `policy-integrity` open — the read-only mount over `.devcontainer` covers the overlay for now | One source of truth. Prose and controls stop drifting. |
| P2 | Task contract, `entry.sh` creates `/run/harness`, `dcc contract`, `policy-helper` compiles the contract into `permissions.deny` | Scope becomes a value. Fail closed at session start. |
| P3 | **done** — hooks and checkers: pre-tool, post-tool, stop; the phase machine; the project overlay | Fast feedback in the loop. |
| P4 | `dcc gate`, `dcc publish`, the run certificate, Option B for the credential | Publication becomes a control. This is the guarantee. |
| P5 | The test suite of section 13, and CI for this repository | The controls stay true over time. |

P0 and P4 carry most of the value. P3 is comfort, not proof.

## 15. Limits

Say these limits out loud. Do not let the harness suggest more than it
gives.

- The agent can run any program. `api.anthropic.com` is on the
  allowlist. The agent can start its own model loop, and managed
  settings do not bind another program. Only layer 2 and layer 3 hold
  there. This is why the firewall, the masks and the gate stay
  authoritative.
- Hooks are not a security boundary. The documentation says so. Some
  tool paths can miss them.
- The rule files in the workspace are agent-writable. Only the image
  copy decides. `policy-integrity` reports the difference.
- Under Codex, `check-tickets-after-change` is a reminder, not a
  guarantee. Claude Code calls `PostToolUse` after a successful tool
  only; Codex also calls it after a **failed** shell command, and its
  `tool_response` for a shell tool is the raw output text with no exit
  status anywhere in the payload. A failing `bin/check-tickets` clears
  the dirty flag too. The session is still forced to run the check; it
  is not forced to make it pass.
- `protected-paths` reads shell commands for write syntax — redirects,
  `cp`, `sed -i` and the like. A program that writes a protected file as
  a side effect is invisible to it. `codex mcp add` is the known case:
  it writes `~/.codex/config.toml`, which the same rule denies when the
  agent writes it directly. The blast radius is bounded by the layer
  below — an MCP server added that way is refused by the requirements
  file — but the general shape is a limit of the rule, not of that one
  command.
- "Keep the code simple and readable" has no mechanical test. It stays a
  human review point, forever.
- Managed settings from a file do not apply to a cloud session on
  claude.ai. This design is for the local podman container.
- A checker with a wrong predicate is a wrong control. Section 13 is not
  optional.

## 16. Decisions for the owner

1. Whether P0 goes into the template now, before the rest exists. It is
   independent and it is small, and it is the phase that covers every
   incident in the extracarts corpus.
2. The first rule set: the 13 enforce rules in
   [rules-extracarts.md](rules-extracarts.md) §4.1 are tested and ready.
3. The two server-side checks in the workflows (release refuses a direct
   push; CI refuses session links), because branch protection is not
   available on the current plan tier.
