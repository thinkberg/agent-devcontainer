# agent-devcontainer

This is a restricted dev container for coding agents such as Claude Code.
The agent works inside the container. You keep your IDE on the host. Both
use the same files.

The container gives these guarantees:

- The only credential inside is one GitHub token with limited permissions.
- The firewall blocks outbound network traffic. It permits only the
  domains on an allowlist.
- Masks hide the files that contain secrets. The agent reads them as
  empty.
- The agent cannot change these rules from inside the container.

A PostgreSQL database is optional. It is off by default. The template
works for one git repository and also for a directory that contains many
repositories.

## How the protection works

- The container runs on rootless podman with `--userns=keep-id`. The agent
  runs as the user `vscode`, which is your own host user on the mounted
  files.
- The firewall starts as root, before all other processes. If the firewall
  fails, the container stops.
- The user `vscode` has no capabilities. `sudo` does not work anywhere in
  the container (`no-new-privileges` blocks setuid).
- The agent cannot give itself network access. It can only ask you to run
  `dcc allow` on the host.
- The token mount and the secret masks are read-only. The container cannot
  remount them (no `CAP_SYS_ADMIN`).
- Protect dangerous operations on the server side (branch protection,
  deploy environments). The container cannot limit the permissions of the
  token.

## Requirements

- **Rootless podman**, version 5.x. On Debian 13, install it with
  `sudo apt install podman`.
- **Node.js with npx**. `dcc` downloads the tool `@devcontainers/cli` on
  demand.
- **tmux stays on the host.** The container has no tmux. Run `dcc` inside
  your own terminal or tmux session.

## Install the dcc command

Run this command one time, from this directory:

```bash
ln -s "$PWD/dcc" ~/.local/bin/dcc
```

## Prepare a project

Step 1: Create the configuration in your project directory. Replace
`myproject` with your project name (lowercase letters, digits, `-`):

```bash
cd ~/src/myproject
dcc init myproject
```

This copies the template into `.devcontainer/` and sets the name. In a git
repository, it also adds `.claude-devcontainer/` to `.gitignore`. That
directory holds the agent's login state. Never commit it.

Step 2: Edit the copied files. They belong to your project now:

| File | What to change |
|------|----------------|
| `.devcontainer/dcc.conf` | The subnet, and the database settings (see below). |
| `.devcontainer/devcontainer.json` | The secret masks (see below), extra features, and environment variables. |
| `.devcontainer/Dockerfile` | Extra tools, in the marked section. |
| `.devcontainer/allowlist.txt` | The domains the agent may connect to. |
| `.devcontainer/setup-project.sh` | Optional. Your project setup (venv, `npm ci`, …). Make it executable. |
| `.devcontainer/rules/rules.json` | The project's harness rules: read-only paths, plan and ticket conventions, project checkers (see below). |

To get template updates later, copy the changed template files into your
`.devcontainer/` again. There is no automatic link. A template change can
never break your project.

## Add your credentials

Do this one time for each project. Each user creates their own set.
First, set the name. Then copy each block:

```bash
NAME=myproject
mkdir -p ~/.config/$NAME-devcontainer
```

Step 1: Create the git identity:

```bash
printf '[user]\n\tname = %s\n\temail = %s\n' \
  'Your Name (agent)' 'you+agent@example.com' \
  > ~/.config/$NAME-devcontainer/gitconfig
```

Verify this email address on GitHub. Then commits show the correct
author.

Step 2: Create a fine-grained GitHub token. Limit it to the repositories
this project needs. Give it these permissions:

- Contents: read and write
- Issues: read and write
- Pull requests: read and write
- Metadata: read
- Workflows: **none**. Without this permission, GitHub rejects every push
  that changes `.github/workflows/`.

Set an expiry date. Set a reminder for the rotation. Then store the
token:

```bash
(umask 077; printf '%s' 'github_pat_…' > ~/.config/$NAME-devcontainer/gh-token)
```

Step 3 (optional): Create a signing key for verified commits:

```bash
ssh-keygen -t ed25519 -N '' -C $NAME-devcontainer \
  -f ~/.config/$NAME-devcontainer/signing-key
```

Add the `.pub` file on GitHub as a **signing** key. Without this file, the
container makes unsigned commits.

## Start the container the first time

```bash
dcc           # builds the image, starts the container, opens a shell
claude        # log in once: open the URL in your HOST browser
```

The container keeps the agent's state in `<project>/.claude-devcontainer`
on the host. The container never mounts the host directory `~/.claude`,
because host transcripts can contain secrets.

Optional: copy your project memory into the container state. Run this on
the host, in the project directory:

```bash
key="-$(pwd | sed 's|^/||; s|/|-|g')"
mkdir -p ".claude-devcontainer/projects/$key"
cp -r "$HOME/.claude/projects/$key/memory" ".claude-devcontainer/projects/$key/"
```

Do not copy transcripts. They can contain secrets.

## Daily commands

| Command              | Function                                                              |
|----------------------|-----------------------------------------------------------------------|
| `dcc`                | Start the container if necessary. Open a shell inside.                |
| `dcc attach <cmd>`   | Run `<cmd>` inside instead of a shell. Example: `dcc attach claude`.  |
| `dcc up <cmd>`       | Start everything, then run `<cmd>`. Use this in scripts.              |
| `dcc down`           | Stop the container and the database. All data stays.                  |
| `dcc rebuild`        | Build a new image and container. The database does not change.        |
| `dcc db reset`       | Delete the database and its data.                                     |
| `dcc allow <domain>` | Permit egress to one domain, until the next restart.                  |
| `dcc fw`             | Run the firewall again, for example after CDN addresses change.       |
| `dcc approve <plan>` | Approve a committed plan; the run may enter phase implement. `--scope <glob>…` limits the writes. |
| `dcc approve-release <repo> <pr>` | Approve the merge of a Release PR at its current head. |
| `dcc check`          | Run the harness gate checks inside the container.                     |
| `dcc harness on\|off` | The harness switch. Off: the hooks make no decisions until `dcc harness on` or the next start. |
| `dcc root`           | Open a root shell in the container. Use this only for repairs.        |

Notes for daily use:

- The shell opens in the same absolute path as on the host. This is
  intentional. Venv shebangs, IDE references, and the agent's project key
  are then correct on both sides.
- Keep your IDE on the host checkout. The files are the same.
- Inside the container, git pushes over HTTPS with the token. `GH_TOKEN`
  is available only in interactive shells. For scripts, use
  `dcc up bash -ic '…'`, not `bash -c`.
- To continue an interrupted agent session, run `dcc attach claude -c`.

## Use the optional database

The database is off by default. To turn it on, edit
`.devcontainer/dcc.conf`:

```bash
DB_IMAGE=docker.io/postgres:16
DB_PORT=5433
DB_ENV="POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres"
```

Facts:

- PostgreSQL runs as a separate container, `<name>-db`. `dcc` manages it.
- The data is in the volume `<name>-pgdata`. A `dcc rebuild` does not
  change it. Only `dcc db reset` deletes it.
- The database initializes one time, on an empty volume, from the scripts in
  `.devcontainer/db-init.d/`.
- Inside the container, connect to `postgres:5432`. From the host (for IDE
  database tools), connect to `127.0.0.1:5433` (the `DB_PORT` value).

Example init script for test suites:

```sql
-- .devcontainer/db-init.d/90-test-role.sql
CREATE ROLE test LOGIN SUPERUSER PASSWORD 'test';
CREATE DATABASE test OWNER test;
```

## Expose a server port to the host

Off by default. To reach a server running inside (e.g. an API on 8000)
from the host, edit `.devcontainer/devcontainer.json`: uncomment the
`--publish=127.0.0.1:8000:8000` line in `runArgs` and list the port in
`DEVCONTAINER_INPUT_PORTS` (the inbound firewall drops unlisted ports).
Then `dcc rebuild`. The server must bind `0.0.0.0` inside; the host side
is loopback-only by design.

For an engine other than PostgreSQL, adapt `ensure_db` in your copy of
`dcc`.

## Control egress

- Permanent: add the domain to `.devcontainer/allowlist.txt`. Then run
  `dcc rebuild`.
- Temporary: run `dcc allow <domain>` on the host. The grant ends when the
  container restarts.
- Do not put production hosts, cloud APIs, and similar domains on the
  list. The agent must ask for them each time.

## Mask secret files

Give every file that contains secrets a mask mount in
`.devcontainer/devcontainer.json`. The `mounts` array is the full
inventory. When you add a secret file to the project, add its mask in the
same change.

Mask one file:

```json
"source=${localWorkspaceFolder}/.devcontainer/empty,target=${localWorkspaceFolder}/.env,type=bind,readonly"
```

Mask a full directory:

```json
"source=${localWorkspaceFolder}/.devcontainer/empty.d,target=${localWorkspaceFolder}/sources,type=bind,readonly"
```

**Warning:** Do not use `type=tmpfs` or `type=volume` as a mask. Podman
copies the hidden content into such mounts. The mask then shows exactly
the secrets it must hide.

## Test the boundary

Run these checks inside the container after the first start. The firewall
also tests itself on every start. If the test fails, the container
stops.

```bash
sudo true                                        # must fail
iptables -L                                      # must show "Permission denied"
curl -s --max-time 5 https://example.com         # must fail (blocked)
curl -s --max-time 10 https://api.github.com/zen # must answer
cat .env                                         # a masked file must be empty
ls sources/                                      # a masked directory must be empty
```

Also make one push that changes `.github/workflows/`. GitHub must reject
it, because the token has no Workflows permission.

## Do these tasks on the host only

- Server provisioning and production SSH.
- Secret rotation, and every step that touches secret values. You run
  these commands in your own terminal. The agent gives you the commands.
  Secret values never go through an agent session.
- Everything that needs a browser session.

## The safety harness

The container also controls what the agent must satisfy at each step of
the work. The image carries a harness (`/usr/local/lib/harness`, from
`.devcontainer/harness/`) and a managed settings file
(`/etc/claude-code/managed-settings.json`) that wires its hooks. Claude
Code reads that file above every other settings level, and
`allowManagedHooksOnly` means the agent cannot add or remove hooks in its
own settings (it also narrows `statusLine` to managed settings, so the
managed file delegates to `~/.claude/statusline-command.sh` — drop your
script into `.claude-devcontainer/`). Both are root-owned in the image; a
change is a rebuild.

What it holds:

- The working process is a state machine: brainstorm → plan → review →
  implement. Before implement the agent writes markdown only. The step
  into implement needs your approval: `dcc approve <plan> [--scope
  <glob>…]` on the host. A plan edited after approval drops the run back
  to review.
- Git hygiene and the publish surface: explicit staging, `-C /absolute`
  on every mutating git command, no `--no-verify`, no push to
  `production`, no session links or Claude trailers in anything that
  reaches GitHub, no remote rewrites.
- Secrets never pass through the session (`gh secret set`, `sops`, `age`,
  SQL passwords are denied). Tickets go through the project's scripts.
- `.devcontainer/` is mounted read-only over itself. The agent proposes
  policy changes as text; you apply them.
- Project checks run after edits, at the end of a session, and on
  demand with `dcc check`.

Your project's own rules — read-only paths, the ticket and plan
conventions, project checkers — go into `.devcontainer/rules/rules.json`
(seeded by `dcc init`). The engine merges them over the generic rules.
Design, rationale and limits: [docs/safety-harness.md](docs/safety-harness.md);
a complete worked example: [docs/rules-extracarts.md](docs/rules-extracarts.md).

To work without the harness for a while, run `dcc harness off` on the
host. The hooks then make no decisions and the plain Claude Code
permission flow applies. The switch is a root-owned marker in
`/run/harness`: the agent can see it (`harness status`) and cannot flip
it. To disable one rule only, add its id to `disabled` in
`.devcontainer/rules/rules.json`.

Approvals and the switch live in `/run/harness` inside the container.
`/run` is fresh on every start: an approval does not survive a restart,
and a restart always starts with the harness on.

## Prior art

- [anthropics/claude-code](https://github.com/anthropics/claude-code) —
  the reference Claude Code devcontainer. The idea of allowlist-only
  egress for agent containers comes from there. The firewall script here
  is an independent implementation.
- [anthropics/devcontainer-features](https://github.com/anthropics/devcontainer-features)
  — the `claude-code` feature that installs the agent into the image.
- [nikvdp/cco](https://github.com/nikvdp/cco) — a thin protective wrapper
  around Claude Code. Its idea guided the design of `dcc`: the sandboxed
  agent must feel like the plain one, with a small host command, a
  persistent login state, and your normal workflow.
- [StefanMaron/claudeCodeAlDevContainer](https://github.com/StefanMaron/claudeCodeAlDevContainer)
  — a hardened Claude Code dev container feature. It treats the agent as
  untrusted for permission-bypass use: dropped capabilities, blocked
  credential prompts, container-private agent state.
- [devcontainers/cli](https://github.com/devcontainers/cli),
  [devcontainers/features](https://github.com/devcontainers/features), and
  [devcontainers/images](https://github.com/devcontainers/images) — the
  dev container specification, the tooling that `dcc` drives, the
  node/python/github-cli features, and the Ubuntu base image.

The additional hardening comes from a private project: rootless podman
with `--userns=keep-id`, the firewall as pid 1 with the capability split,
disabled sudo, the secret masks, and the sidecar setup. This template is
the extracted, generic version.

## License

MIT, see [LICENSE](LICENSE).

---

This document uses the rules of
[Simplified Technical English](https://en.wikipedia.org/wiki/Simplified_Technical_English).
