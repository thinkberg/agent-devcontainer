# Restricted dev container for a Claude Code agent. Toolchain (node, gh,
# claude) comes from devcontainer features on top of this image; a database,
# if any, runs as a sidecar service (see dcc), not in here.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ipset iptables dnsutils jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- project tools (edit freely) ------------------------------------------
# client for the postgres sidecar:
# RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
#     && rm -rf /var/lib/apt/lists/*
# uv (python tooling):
# RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
# hugo extended (pin to the deploy workflow's version):
# ARG HUGO_VERSION=0.163.2
# RUN curl -fsSL "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz" \
#         | tar -xz -C /usr/local/bin hugo
# ----------------------------------------------------------------------------

# NOTE: the firewall script name must stay unique — the claude-code feature
# installs its own /usr/local/bin/init-firewall.sh after this Dockerfile runs
COPY allowlist.txt /etc/devcontainer-allowlist.txt
COPY devcontainer-firewall.sh entry.sh setup-workspace.sh cc-allow.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/devcontainer-firewall.sh /usr/local/bin/entry.sh \
        /usr/local/bin/setup-workspace.sh /usr/local/bin/cc-allow.sh

# GH_TOKEN (scoped PAT) into every interactive shell; bashrc, not profile.d,
# because podman-exec shells are interactive non-login
RUN printf '%s\n' \
        'if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.config/devcontainer/gh-token" ]; then' \
        '  export GH_TOKEN="$(cat "$HOME/.config/devcontainer/gh-token")"' \
        'fi' >> /etc/bash.bashrc

# no sudo surface at all: no-new-privileges (runArgs) makes setuid inert, so
# the base image's NOPASSWD grant and any feature-installed sudoers are dead
# weight; root work runs as pid 1 (entry.sh) or via podman exec -u root
RUN rm -f /etc/sudoers.d/* && gpasswd -d vscode sudo 2>/dev/null || true

# firewall before anything else, as root, on every start (overrideCommand:
# false in devcontainer.json keeps this in charge)
ENTRYPOINT ["/usr/local/bin/entry.sh"]
