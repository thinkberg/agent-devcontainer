#!/bin/bash
# Container entrypoint (pid 1, root-in-userns): the firewall comes up BEFORE
# anything else can run — lifecycle scripts and all sessions run as vscode
# (remoteUser) and cannot touch it (no caps, sudo dead via
# no-new-privileges). Root work happens here or via `dcc …` (podman exec -u
# root) from the host. Failure-closed: if the firewall script fails, pid 1
# exits and the container stops.
set -euo pipefail

/usr/local/bin/devcontainer-firewall.sh

# named volumes arrive root-owned on first mount; hand them to vscode
# (DEVCONTAINER_CHOWN: space-separated absolute paths, devcontainer.json)
for d in ${DEVCONTAINER_CHOWN:-}; do chown vscode: "$d"; done

# harness run state: the agent writes its phase into agent/, the operator's
# approvals land in approvals/ via `dcc approve` (podman exec -u root) —
# vscode can read them and cannot write them. /run is fresh on every start:
# an approval does not survive a container restart.
mkdir -p /run/harness/agent /run/harness/approvals
chown vscode: /run/harness/agent
chmod 755 /run/harness /run/harness/approvals

touch /run/devcontainer-entry-done   # setup-workspace.sh waits for this
exec sleep infinity
