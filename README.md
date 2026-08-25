# agent-devcontainer

This is a restricted dev container for agents such as Claude Code that
write code. The agent operates in the container. You keep your IDE on
the host. The agent and the IDE use the same files.

The container gives these guarantees:

- The only credential in the container is one GitHub token with a small
  set of permissions.
- The firewall blocks outbound network traffic. It lets through only the
  domains on an allowlist.
- Masks replace the files that contain secrets. The agent sees empty
  files.
- A harness enforces the working process: plan, review, your approval,
  then code. Hooks deny the commands and edits that the rules reject.
- The agent cannot change these rules in the container.

A PostgreSQL database is optional. It is off by default. The template
is applicable to one git repository and to a directory that contains
many repositories.

## How the protection works

- The container runs on rootless podman with `--userns=keep-id`. The agent
  runs as the user `vscode`, which is your host user on the mounted
  files.
- The firewall starts as root, before all other processes. If the firewall
  does not start, the container stops.
- The user `vscode` has no capabilities. `sudo` does not operate in the
  container (`no-new-privileges` blocks setuid).
- The agent cannot get network access. The agent can only tell you to run
  `dcc allow` on the host.
- The token mount and the secret masks are read-only. The container cannot
  remount these mounts (no `CAP_SYS_ADMIN`).
- Root-owned managed settings, which Claude Code reads above all other
  settings levels, connect the harness hooks. The agent cannot add,
  remove or bypass the hooks. Only the host writes approvals.
- Use the server side (branch protection, deploy environments) to prevent
  unwanted operations. The container cannot decrease the permissions of
  the token.

## Necessary tools

- **Rootless podman**, version 5.x. On Debian 13, install it with
  `sudo apt install podman`.
- **Node.js with npx**. `dcc` downloads the tool `@devcontainers/cli` when
  necessary.
- **tmux stays on the host.** The container has no tmux. Run `dcc` in
  your terminal or tmux session.

<!-- ste: procedure -->

## Install the dcc command

Run this command one time, from this directory:

```bash
ln -s "$PWD/dcc" ~/.local/bin/dcc
```

## Prepare a project

Step 1: Make the configuration in your project directory. Replace
`myproject` with your project name (only `a-z`, `0-9` and `-`):

```bash
cd ~/src/myproject
dcc init myproject
```

The command copies the template into `.devcontainer/` and sets the name.
In a git repository, the command also adds `.claude-devcontainer/` to
`.gitignore`. That directory holds the login state of the agent. Do not
commit that directory.

Step 2: Edit the copied files. The files are part of your project:

| File | Change |
|------|--------|
| `.devcontainer/dcc.conf` | The subnet, and the database settings (see below). |
| `.devcontainer/devcontainer.json` | The secret masks (see below), other features, and environment variables. |
| `.devcontainer/Dockerfile` | Other tools, in the marked section. |
| `.devcontainer/allowlist.txt` | The domains that the agent can connect to. |
| `.devcontainer/setup-project.sh` | Optional. Your project setup (venv, `npm ci`, …). Make it executable. |
| `.devcontainer/rules/rules.json` | The harness rules of the project (see [The safety harness](#the-safety-harness)). |

To get new template files, copy the changed template files into your
`.devcontainer/` again. There is no automatic link. A template change
cannot break your project.

## Add your credentials

Do this procedure one time for each project. Each user makes a set.
First, set the name. Then copy each block:

```bash
NAME=myproject
mkdir -p ~/.config/$NAME-devcontainer
```

Step 1: Make the git identity:

```bash
printf '[user]\n\tname = %s\n\temail = %s\n' \
  'Your Name (agent)' 'you+agent@example.com' \
  > ~/.config/$NAME-devcontainer/gitconfig
```

Verify this email address on GitHub. Then the commits show the correct
name.

Step 2: Make a GitHub token of the type `fine-grained`. Give the token
access to only the repositories of this project. Give the token these
permissions:

- Contents: read and write
- Issues: read and write
- `Pull requests`: read and write
- Metadata: read
- Workflows: **none**. Without this permission, GitHub rejects each push
  that changes `.github/workflows/`.

Set an expiry date. Record the rotation date. Then write the token to
a file:

```bash
(umask 077; printf '%s' 'github_pat_…' > ~/.config/$NAME-devcontainer/gh-token)
```

Step 3 (optional): Make a signing key for signed commits:

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

The container keeps the state of the agent in `<project>/.claude-devcontainer`
on the host. The container does not mount the host directory `~/.claude`,
because host transcripts can contain secrets.

Optional: copy your project memory into the container state. Run these
commands on the host, in the project directory:

```bash
key="-$(pwd | sed 's|^/||; s|/|-|g')"
mkdir -p ".claude-devcontainer/projects/$key"
cp -r "$HOME/.claude/projects/$key/memory" ".claude-devcontainer/projects/$key/"
```

Do not copy transcripts. They can contain secrets.

<!-- ste: description -->

## Commands

| Command              | Function                                                              |
|----------------------|-----------------------------------------------------------------------|
| `dcc`                | Start the container if necessary. Open a shell in the container.      |
| `dcc attach <cmd>`   | Run `<cmd>` in the container, not a shell. Example: `dcc attach claude`. |
| `dcc up <cmd>`       | Start the container and the database, then run `<cmd>`. Use this in scripts. |
| `dcc down`           | Stop the container and the database. All data stays.                  |
| `dcc rebuild`        | Build a new image and container. The database does not change.        |
| `dcc db reset`       | Remove the database and its data.                                     |
| `dcc allow <domain>` | Let egress through to one domain, until the next restart.             |
| `dcc fw`             | Run the firewall again, for example after CDN addresses change.       |
| `dcc approve <plan>` | Approve a committed plan. The run can then go to phase implement. `--scope <glob>…` limits the writes. |
| `dcc approve-release <repo> <pr>` | Approve the merge of a Release PR at the head of the PR. |
| `dcc check`          | Run the harness gate checks in the container.                         |
| `dcc harness on\|off` | The harness switch. Off: the hooks make no decisions until `dcc harness on` or the next start. |
| `dcc root`           | Open a root shell in the container. Use this only for repairs.        |

Notes:

- The shell opens in the same absolute path as on the host. This is
  necessary: venv shebangs, IDE paths and the project key of the agent
  are then correct on the host and in the container.
- Keep your IDE on the host checkout. The files are the same.
- In the container, git pushes with HTTPS and the token. `GH_TOKEN`
  is available only in interactive shells. For scripts, use
  `dcc up bash -ic '…'`, not `bash -c`.
- To continue a stopped agent session, run `dcc attach claude -c`.

## Use the optional database

The database is off by default. To set the database to on, edit
`.devcontainer/dcc.conf`:

```bash
DB_IMAGE=docker.io/postgres:16
DB_PORT=5433
DB_ENV="POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres"
```

Facts:

- PostgreSQL runs in a different container, `<name>-db`. `dcc` controls this
  container.
- The data is in the volume `<name>-pgdata`. A `dcc rebuild` does not
  change it. Only `dcc db reset` removes the data.
- The database initializes one time, on an empty volume, from the scripts in
  `.devcontainer/db-init.d/`.
- In the container, connect to `postgres:5432`. From the host (for IDE
  database tools), connect to `127.0.0.1:5433` (the `DB_PORT` value).

Example init script for test suites:

```sql
-- .devcontainer/db-init.d/90-test-role.sql
CREATE ROLE test LOGIN SUPERUSER PASSWORD 'test';
CREATE DATABASE test OWNER test;
```

<!-- ste: procedure -->

## Expose a server port to the host

Off by default. This procedure opens a port of the container on the
host, for example an API on port 8000.

1. Edit `.devcontainer/devcontainer.json`.
2. Uncomment the `--publish=127.0.0.1:8000:8000` line in `runArgs`.
3. Add the port to `DEVCONTAINER_INPUT_PORTS`. The inbound firewall
   blocks the ports that are not in this list.
4. Run `dcc rebuild`.

The server must bind `0.0.0.0` in the container. The host side is
loopback only.

For an engine other than PostgreSQL, adapt `ensure_db` in your copy of
`dcc`.

## Control egress

- Permanent: add the domain to `.devcontainer/allowlist.txt`. Then run
  `dcc rebuild`.
- For one session: run `dcc allow <domain>` on the host. The grant stops
  when the container restarts.
- Do not put production hosts, cloud APIs and domains of that type on
  the list. For these domains, the agent must tell you each time. You
  then run `dcc allow`.

## Mask secret files

Give each file that contains secrets a mask mount in
`.devcontainer/devcontainer.json`. The `mounts` array is the full
inventory. When you add a secret file to the project, add the mask in
the same change.

Mask one file:

```json
"source=${localWorkspaceFolder}/.devcontainer/empty,target=${localWorkspaceFolder}/.env,type=bind,readonly"
```

Mask a full directory:

```json
"source=${localWorkspaceFolder}/.devcontainer/empty.d,target=${localWorkspaceFolder}/sources,type=bind,readonly"
```

**Warning:** Do not use `type=tmpfs` or `type=volume` as a mask. Podman
copies the masked files into mounts of these types. The mask then shows
the secrets.

## Test the boundary

Run these checks in the container after the first start. The firewall
also does a check at each start. If the check is not satisfactory, the
container stops.

```bash
sudo true                                        # must fail
iptables -L                                      # must show "Permission denied"
curl -s --max-time 5 https://example.com         # must fail (blocked)
curl -s --max-time 10 https://api.github.com/zen # must answer
cat .env                                         # a masked file must be empty
ls sources/                                      # a masked directory must be empty
```

Also make one push that changes `.github/workflows/`. GitHub must reject
the push, because the token has no Workflows permission.

<!-- ste: description -->

## Do these tasks on the host only

- Server provisioning and production SSH.
- Secret rotation, and each step that touches secret values. You run
  these commands in your terminal. The agent gives you the commands.
  Secret values do not go through an agent session.
- All tasks for which a browser session is necessary.

## The safety harness

The image also has a harness: hooks that Claude Code runs before and
after each tool call, a `harness` CLI, checkers, and a rule registry. The
agent gives a tool call; the harness accepts or denies the tool call. The
harness is root-owned, and managed settings connect the hooks. A change
is a rebuild.

The harness gives you:

- a working process as a state machine: brainstorm → plan → review →
  implement. Your approval on the host is the step into code
  (`dcc approve`, `dcc approve-release`);
- 22 generic rules on git, the publish step, secrets, tickets and protected
  paths, each classed as enforce, verify, approve or advise;
- checkers that run after an edit, at the session end and with
  `dcc check`;
- a project overlay in `.devcontainer/rules/` for the rules and checkers
  of your project;
- an off switch, `dcc harness off|on`.

Full description and procedures: [docs/harness-ste.md](docs/harness-ste.md).
The plan and the limits:
[docs/safety-harness.md](docs/safety-harness.md). A complete worked
example: [docs/rules-extracarts.md](docs/rules-extracarts.md). The
engine: [template/harness/README.md](template/harness/README.md).

## Sources

- [anthropics/claude-code](https://github.com/anthropics/claude-code) —
  the Claude Code devcontainer of Anthropic. The allowlist-only egress
  for agent containers comes from there. The firewall script here is new
  code.
- [anthropics/devcontainer-features](https://github.com/anthropics/devcontainer-features)
  — the `claude-code` feature that installs the agent into the image.
- [nikvdp/cco](https://github.com/nikvdp/cco) — a thin protective wrapper
  around Claude Code. `dcc` does the same. The sandboxed agent must
  operate as the usual agent does. The user has a small host command, a
  persistent login state and the usual workflow.
- [StefanMaron/claudeCodeAlDevContainer](https://github.com/StefanMaron/claudeCodeAlDevContainer)
  — a hardened dev container feature for Claude Code. In that feature
  the agent is untrusted, also in permission-bypass mode. The feature
  removes the capabilities and blocks credential prompts. The agent
  state stays in the container.
- [devcontainers/cli](https://github.com/devcontainers/cli),
  [devcontainers/features](https://github.com/devcontainers/features), and
  [devcontainers/images](https://github.com/devcontainers/images) — the
  dev container specification and the tools that `dcc` uses. The node,
  python and github-cli features and the Ubuntu base image come from
  there.

The other hardening comes from a private project:

- rootless podman with `--userns=keep-id`;
- the firewall as pid 1, with root capabilities only for the firewall;
- sudo off;
- the secret masks;
- the sidecar setup.

This template is the generic version of that project.

## License

MIT, see [LICENSE](LICENSE).

---

This document uses the rules of
[Simplified Technical English](https://en.wikipedia.org/wiki/Simplified_Technical_English).
