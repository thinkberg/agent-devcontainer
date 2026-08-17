#!/bin/bash
# User-level postCreate (runs as vscode, cwd = workspace root): git wiring,
# then the project's own bootstrap. No sudo, by design.
set -euo pipefail

# entry.sh (pid 1) may still be bringing the firewall up; wait so anything
# setup-project.sh downloads runs inside the boundary, not before it
for _ in $(seq 60); do [ -f /run/devcontainer-entry-done ] && break; sleep 1; done
[ -f /run/devcontainer-entry-done ] || { echo "ERROR: entry.sh (firewall) never finished" >&2; exit 1; }

# identity (user.name/email) comes from the mounted config dir, not any
# repo — see README "Per-user credentials"
git config --global include.path "$HOME/.config/devcontainer/gitconfig"
# host repos may be cloned with ssh remotes; in here everything goes HTTPS
# with the scoped PAT
git config --global url."https://github.com/".insteadOf "git@github.com:"
if [ -r "$HOME/.config/devcontainer/gh-token" ]; then
    GH_TOKEN="$(cat "$HOME/.config/devcontainer/gh-token")" gh auth setup-git
fi
if [ -r "$HOME/.config/devcontainer/signing-key" ]; then
    git config --global gpg.format ssh
    git config --global user.signingkey "$HOME/.config/devcontainer/signing-key"
    git config --global commit.gpgsign true
fi

# project bootstrap (venvs, npm ci, …) — optional, lives with the project
if [ -x .devcontainer/setup-project.sh ]; then
    .devcontainer/setup-project.sh
fi
