# Restricted dev container for coding agents. Node, gh and Claude come from
# devcontainer features; Codex is installed below. A database, if any, runs as
# a sidecar service (see dcc), not in here.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ipset iptables dnsutils jq curl ca-certificates python3 bubblewrap \
    && rm -rf /var/lib/apt/lists/*

ARG CODEX_VERSION=latest
RUN curl -fsSL https://chatgpt.com/codex/install.sh \
        | env CODEX_RELEASE="$CODEX_VERSION" CODEX_NON_INTERACTIVE=1 \
              CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/usr/local/lib/codex sh

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
# headless chrome (Google's deb; Ubuntu's apt "chromium" is a snap stub and
# node/playwright arrive after this Dockerfile). amd64 only. Launch with
# --no-sandbox: Chrome's own sandbox dies at sys_chroot (podman's seccomp
# gates chroot on CAP_SYS_CHROOT, dropped by --cap-drop=ALL); the container
# is the sandbox. See --shm-size and the *_SKIP_* env in devcontainer.json.
# fonts-noto-cjk: CJK text renders as boxes without it; add fonts-noto-color-emoji
# or fonts-noto-core for emoji / other scripts the same way:
# RUN curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
#     && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/chrome.deb fonts-noto-cjk \
#     && rm -rf /tmp/chrome.deb /var/lib/apt/lists/* /etc/apt/sources.list.d/google-chrome* /etc/cron.daily/google-chrome
# ----------------------------------------------------------------------------

# ---- safety harness -------------------------------------------------------
# The engine (hooks, checkers, generic rules) and the managed settings that
# wire it. Both root-owned in the image: vscode can run them, not change
# them; a change is a host-side rebuild, like allowlist.txt. Claude Code and
# Codex read their root-owned managed policy, which permits only these hooks.
# The project's rules stay in the workspace (.devcontainer/rules/, mounted
# read-only by devcontainer.json).
COPY harness/ /usr/local/lib/harness/
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY codex-requirements.toml /etc/codex/requirements.toml
RUN rm -rf /usr/local/lib/harness/tests \
    && chmod -R u=rwX,go=rX /usr/local/lib/harness /etc/claude-code /etc/codex \
    && ln -s /usr/local/lib/harness/harness.py /usr/local/bin/harness

# NOTE: the firewall script name must stay unique — the claude-code feature
# installs its own /usr/local/bin/init-firewall.sh after this Dockerfile runs
COPY allowlist.txt /etc/devcontainer-allowlist.txt
COPY devcontainer-firewall.sh entry.sh setup-workspace.sh cc-allow.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/devcontainer-firewall.sh /usr/local/bin/entry.sh \
        /usr/local/bin/setup-workspace.sh /usr/local/bin/cc-allow.sh

# git asks gh for the token on every HTTPS push. Baked into the system
# config, so it works no matter when the token file appears (postCreate runs
# once; a token added after that used to leave git with no credential helper)
RUN printf '[credential "https://github.com"]\n\thelper = !gh auth git-credential\n' > /etc/gitconfig

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
