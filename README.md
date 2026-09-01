# agent-devcontainer

This is a restricted dev container for Claude Code and OpenAI Codex that
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

- The container runs on rootless podman with
  `--userns=keep-id:uid=1000,gid=1000`. The agent runs as the user
  `vscode`, which is your host user on the mounted files. The mapping is
  correct for each host uid, also for uid 501 on macOS.
- The firewall starts as root, before all other processes. If the firewall
  does not start, the container stops.
- The user `vscode` has no capabilities. `sudo` does not operate in the
  container (`no-new-privileges` blocks setuid).
- The agent cannot get network access. The agent can only tell you to run
  `dcc allow` on the host.
- The token mount and the secret masks are read-only. The container cannot
  remount these mounts (no `CAP_SYS_ADMIN`).
- Root-owned Claude managed settings and Codex requirements connect the
  harness hooks. The agent cannot add, remove or bypass the hooks. Only
  the host writes approvals.
- Use the server side (branch protection, deploy environments) to prevent
  unwanted operations. The container cannot decrease the permissions of
  the token.

## Necessary tools

- **Rootless podman**, version 5.x. On Debian 13, install it with
  `sudo apt install podman`.
- On macOS, install podman with `brew install podman`. Then make the VM
  one time: `podman machine init`, then `podman machine start`. The VM
  mounts `/Users`. Keep the projects in `/Users`.
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
In a git repository, the command also adds `.claude-devcontainer/` and
`.codex-devcontainer/` to `.gitignore`. These directories hold agent login
state. Do not commit them.

Step 2: Edit the copied files. The files are part of your project:

| File | Change |
|------|--------|
| `.devcontainer/dcc.conf` | The subnet, and the database settings (see below). |
| `.devcontainer/devcontainer.json` | The secret masks (see below), other features, and environment variables. |
| `.devcontainer/Dockerfile` | Other tools, in the marked section. |
| `.devcontainer/allowlist.txt` | The domains that the agent can connect to. |
| `.devcontainer/setup-project.sh` | Optional. Your project setup (venv, `npm ci`, …). Make it executable. |
| `.devcontainer/update` | Brings the engine files up to date with the template on GitHub and merges your configuration files (see [Updates](#updates)). |
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

Optional: copy the agent settings from a project that exists. Give the
name of a started project, or its directory:

```bash
dcc seed extracarts
```

The command copies `statusline-command.sh`, `settings.json`, the Codex
`config.toml` (with the project path changed) and the git identity. It
does not overwrite a file that exists. It does not copy the GitHub token,
the signing key or the logins. These are per project.

```bash
dcc           # builds the image, starts the container, opens a shell
claude        # log in once: open the URL in your HOST browser
codex login --device-auth  # Codex: open the URL in your HOST browser
```

The container keeps agent state in `<project>/.claude-devcontainer` and
`<project>/.codex-devcontainer` on the host. It does not mount the host
directories `~/.claude` or `~/.codex`, because transcripts can contain
secrets. If you set Codex's sandbox mode there, put it before every TOML
table header:

```toml
sandbox_mode = "danger-full-access"

[projects."/absolute/path/to/project"]
trust_level = "trusted"
```

Putting `sandbox_mode` after `[projects."…"]` nests it in that project table,
so Codex ignores it, defaults to `workspace-write`, and warns that the mode is
disallowed by `/etc/codex/requirements.toml`. Do not remove `read-only` from
`allowed_sandbox_modes` to silence the warning; Codex needs it during login.

Codex can alternatively use an API key:

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

Optional: copy your project memory into the container state. Run these
commands on the host, in the project directory:

```bash
key="-$(pwd | sed 's|^/||; s|/|-|g')"
mkdir -p ".claude-devcontainer/projects/$key"
cp -r "$HOME/.claude/projects/$key/memory" ".claude-devcontainer/projects/$key/"
```

Do not copy transcripts. They can contain secrets.

The two agents read different instruction files from the workspace:
Claude Code reads `CLAUDE.md`, Codex reads `AGENTS.md`. If you use both,
keep the rules in one file and let the other point to it. The harness
does not depend on either file — the rules in `.devcontainer/rules/` bind
both agents.

<!-- ste: description -->

## Commands

| Command              | Function                                                              |
|----------------------|-----------------------------------------------------------------------|
| `dcc`                | Start the container if necessary. Open a shell in the container.      |
| `dcc attach <cmd>`   | Run `<cmd>` in the container, not a shell. Example: `dcc attach claude` or `dcc attach codex`. |
| `dcc up <cmd>`       | Start the container and the database, then run `<cmd>`. Use this in scripts. |
| `dcc down`           | Stop the container and the database. All data stays.                  |
| `dcc rebuild`        | Build a new image and container. The database does not change.        |
| `dcc update`         | Update `.devcontainer` from the template on GitHub, keep the configuration. Then `dcc rebuild`. |
| `dcc seed [project]` | Copy the agent settings from a project that exists (name or directory), not the tokens. Without an argument, the command asks. |
| `dcc db reset`       | Remove the database and its data.                                     |
| `dcc allow <domain>` | Let egress through to one domain, until the next restart.             |
| `dcc chrome on\|off\|status` | Open your Chrome (the Claude in Chrome extension) to the agent, until `dcc chrome off` or the next restart. Linux hosts only. |
| `dcc fw`             | Run the firewall again, for example after CDN addresses change.       |
| `dcc approve <plan>` | Approve a committed plan. The run can then go to phase implement. `--scope <glob>…` limits the writes. |
| `dcc approve-release <repo> <pr>` | Approve the merge of a Release PR at the head of the PR. |
| `dcc check`          | Run the harness gate checks in the container.                         |
| `dcc harness on\|off` | The harness switch. Off: the hooks make no decisions until `dcc harness on` or the next start. |
| `dcc root [cmd]`     | Open a root shell in the container, or run `cmd` as root. Repairs only. |

Notes:

- The shell opens in the same absolute path as on the host. This is
  necessary: venv shebangs, IDE paths and the project key of the agent
  are then correct on the host and in the container.
- Keep your IDE on the host checkout. The files are the same.
- In the container, git pushes with HTTPS and the token. `GH_TOKEN`
  is available only in interactive shells. For scripts, use
  `dcc up bash -ic '…'`, not `bash -c`.
- To continue a stopped session: `dcc attach claude -c`, or
  `dcc attach codex resume --last`.
- For scripts, `dcc attach codex exec --json "task"` emits Codex JSONL.

## Updates

The template changes. To get the changes into a project, run
`dcc update` (or `.devcontainer/update`) in the project, then
`dcc rebuild`. The script needs no clone of this repository: it reads
the template from GitHub.

- Engine files are replaced: `harness/`, `managed-settings.json`,
  `codex-requirements.toml`,
  `entry.sh`, the firewall and setup scripts, and `update` itself.
- Configuration files get a three-way merge: `devcontainer.json`,
  `Dockerfile`, `dcc.conf`, `allowlist.txt`. The base is the template
  version in `.devcontainer/template.rev`, the commit the project is at
  (written by `dcc init` and by each update). A clean merge is applied. A conflict does not change
  your file: the script writes `<file>.conflict` with conflict markers.
  Resolve it and move the result over your file.
- `rules/`, `empty.d/`, `db-init.d/` and files that are not in the
  template stay as they are.

A project from before `template.rev` existed has no base. The first
update then writes `<file>.conflict` with the new template version for
each configuration file that differs, and records the version. If you
know the template commit the project started from, `dcc update --since
<commit>` merges instead.

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

## Use headless Chrome

Off by default. This procedure installs Google Chrome for browser tests
(Playwright, Puppeteer) or screenshots.

1. Edit `.devcontainer/Dockerfile`. Uncomment the `google-chrome` block in
   the project tools section.
2. Edit `.devcontainer/devcontainer.json`. Uncomment `--shm-size=1g` in
   `runArgs` and the three `PUPPETEER_*` / `PLAYWRIGHT_*` lines in
   `containerEnv`.
3. Run `dcc rebuild`.
4. Start Chrome with `--no-sandbox`. Example for Playwright:
   `chromium.launch({ channel: 'chrome', args: ['--no-sandbox'] })`.

Facts:

- Chrome's own sandbox does not operate in the container: it stops at
  `sys_chroot`, because podman's seccomp profile permits `chroot` only with
  `CAP_SYS_CHROOT`, and `--cap-drop=ALL` removes that capability. Without
  `--no-sandbox`, Chrome stops with a core dump. The container is the
  sandbox; the firewall and the capability limits apply to Chrome too.
- The block installs `fonts-noto-cjk` alongside Chrome, so Japanese,
  Chinese and Korean text renders. Other scripts or emoji need their own
  package on that line (`fonts-noto-core`, `fonts-noto-color-emoji`).
- The `*_SKIP_*` variables stop `npm install` from downloading a browser.
  The firewall blocks that download. Use the system Chrome.
- Chrome's own connections (updates, safe browsing) are blocked by the
  firewall. This causes no problem. Add the sites that the agent must open
  to `allowlist.txt`.
- The harness knows this rule. A file edit that launches Chrome without
  `--no-sandbox` gets a note after the edit (`chrome-no-sandbox`, feedback
  only). A shell command `google-chrome …` without the flag is denied
  (`chrome-no-sandbox-shell`).

## Use your Chrome from the container

Off by default. Linux hosts only. This procedure lets the agent operate
your Chrome through the Claude in Chrome extension (`claude --chrome`),
between `dcc chrome on` and `dcc chrome off`.

How it works: the extension keeps a native host running on the host. The
native host listens on a Unix socket in `/tmp/claude-mcp-browser-bridge-<user>/`.
Claude Code in the container looks in the same directory for the user
`vscode`. That directory is a read-only bind mount of `/tmp/dcc-<name>-chrome`,
a directory that `dcc up` makes. `dcc chrome on` puts a hard link of the
socket in that directory. `dcc chrome off` removes the link and stops the
processes in the container that hold a connection.

1. Install the Claude in Chrome extension on the host. Sign in with the
   claude.ai account that the container uses.
2. Edit `.devcontainer/devcontainer.json`. Uncomment the
   `/tmp/dcc-<name>-chrome` mount.
3. Run `dcc rebuild`.
4. Start Chrome on the host. Run `dcc chrome on`.
5. In the container, start `claude --chrome`. In a session that already
   runs, use `/chrome` → "Reconnect extension". The browser tools
   (`mcp__claude-in-chrome__*`) are then available.
6. Run `dcc chrome off` when the task is complete.

Facts:

- The grant stops at `dcc chrome off` and at each container start.
  `dcc chrome status` shows the state.
- Without the link, no process in the container can reach the socket.
  The mount is read-only: the agent cannot put a socket in it.
- When Chrome restarts, the native host gets a new socket. The link is
  then stale, and `dcc chrome status` says so. Run `dcc chrome on` again.
- The extension's site-level permissions and its permission prompts
  apply. The prompts appear in your Chrome. Bypass permissions mode is
  off in the container (managed settings), so Claude Code does not skip
  these prompts.
- The host and the container can use the extension at the same time.
  The native host accepts more than one client.
- The container login must be `/login`. The extension does not accept a
  `claude setup-token` token or an API key.
- Not on macOS: the socket is in the macOS `/tmp`. The podman VM cannot
  connect to it.

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
- All tasks for which a browser session is necessary. The exception is a
  task for which you run `dcc chrome on` (see
  [Use your Chrome from the container](#use-your-chrome-from-the-container)).

## The safety harness

The image also has a harness: hooks that Claude Code and Codex run before
and after each tool call, a `harness` CLI, checkers, and a rule registry.
The agent gives a tool call; the harness accepts or denies the tool call.
The harness is root-owned, and managed policy connects the hooks. A change
is a rebuild.

The harness gives you:

- a working process as a state machine: brainstorm → plan → review →
  implement. Your approval on the host is the step into code
  (`dcc approve`, `dcc approve-release`);
- 24 generic rules on git, the publish step, secrets, tickets, headless chrome and protected
  paths, each classed as enforce, verify, approve or advise;
- checkers that run after an edit, at the session end and with
  `dcc check`;
- a project overlay in `.devcontainer/rules/` for the rules and checkers
  of your project;
- an off switch, `dcc harness off|on`.

The hooks are wired for both agents and were tested against both. One
guarantee is weaker under Codex: a session that changed tickets must
still run `bin/check-tickets`, but a *failing* check clears the flag,
because Codex reports no exit status to the hook. The limits are in
[docs/safety-harness.md](docs/safety-harness.md) §15.

Full description and procedures: [docs/harness-ste.md](docs/harness-ste.md).
The plan and the limits:
[docs/safety-harness.md](docs/safety-harness.md). A complete worked
example: [docs/rules-extracarts.md](docs/rules-extracarts.md). The
engine: [template/harness/README.md](template/harness/README.md).

## Sources

- [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli),
  [authentication](https://learn.chatgpt.com/docs/auth), and
  [hooks](https://learn.chatgpt.com/docs/hooks) — installation, isolated
  login state and the managed hook protocol used by this template.

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
