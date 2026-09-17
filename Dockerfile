# Hermes agent, pre-configured from the `hermes setup` run in ./config and
# packaged for `dr workload up`.
#
# :latest is what `hermes setup` ran against and what ./config was written for.
# Pin to a release tag (e.g. :v2026.8.19) for a reproducible deploy, but check
# `_config_version` in config.yaml when moving between releases.
FROM nousresearch/hermes-agent:latest

# The Workload API runs containers as uid 1000 on a read-only root filesystem
# with only /tmp writable. Two consequences shape everything below:
#
#   1. The image's `hermes` user is uid 10000, and the base image's wrapper
#      refuses to start under "an arbitrary, non-hermes UID". Remapping hermes
#      to 1000 makes the platform's uid the hermes uid, so getpwuid() resolves
#      and the baked files are owned by whoever actually runs them.
#   2. HERMES_HOME cannot live at the base image's /opt/data, because nothing
#      outside /tmp is writable. The seed is baked read-only and copied into
#      /tmp on boot by docker/entrypoint.sh.
USER root
RUN usermod  --uid 1000 hermes \
    && groupmod --gid 1000 hermes \
    && chown -R 1000:1000 /opt/data

# The declarative half of ./config -- portable, arch-independent, safe to
# freeze into a layer. Deliberately NOT copied (see .dockerignore):
#   * .env / auth.json  -> secrets; injected as workload env vars instead
#   * state.db, logs/, sessions/, cache/  -> runtime state
#   * bin/, .local/, .cua-driver/  -> host-arch (arm64) binaries from setup
ENV HERMES_SEED=/opt/hermes-seed

# Defaults for config.yaml's ${LLM_*} substitutions -- swap in a different
# chat_completions gateway by overriding these at the workload level instead
# of editing config.yaml. LLM_API_KEY has no default here; it's a secret and
# comes solely from the workload's injected credential (.datarobot.yaml).
ENV LLM_MODEL=anthropic/claude-opus-4-8 \
    LLM_PROVIDER=custom \
    LLM_BASE_URL=https://app.datarobot.com/api/v2/genai/llmgw \
    LLM_API_MODE=chat_completions

# dr-sync's endpoint (see the vendor/dr-sync COPY below); non-secret, so it
# defaults here too. DATAROBOT_API_TOKEN and DR_SYNC_CATALOG_ID have no
# default -- see .datarobot.yaml.
ENV DATAROBOT_ENDPOINT=https://app.datarobot.com/api/v2 \
    DATAROBOT_OTEL_ENDPOINT=https://app.datarobot.com/otel \
    DR_SYNC_INTERVAL_SECONDS=600

COPY --chown=1000:1000 config/config.yaml          ${HERMES_SEED}/config.yaml
COPY --chown=1000:1000 config/SOUL.md              ${HERMES_SEED}/SOUL.md
COPY --chown=1000:1000 config/slack-manifest.json  ${HERMES_SEED}/slack-manifest.json
COPY --chown=1000:1000 config/skills/              ${HERMES_SEED}/skills/
# Only a template -- it renders to hermes_otel.yaml at boot, once
# DATAROBOT_API_TOKEN (a secret) is available as a real env var. See
# docker/entrypoint.sh and README.md's "Exporting traces to DataRobot".
COPY --chown=1000:1000 config/hermes_otel.yaml.tmpl ${HERMES_SEED}/hermes_otel.yaml.tmpl
# Without this, dr-sync download finds no .drsyncignore at $HERMES_HOME (its
# default ignore-file lookup is relative to the sync root) and freely
# restores whatever the Files API container has for config.yaml/SOUL.md/
# skills/, clobbering the fresh seed copy entrypoint.sh just placed there.
COPY --chown=1000:1000 config/.drsyncignore        ${HERMES_SEED}/.drsyncignore

# hermes-otel (github.com/briancaffey/hermes-otel): an OpenTelemetry plugin
# that turns Hermes' LLM calls, tool calls and API requests into OTel spans.
# Installed straight into the seed (not $HERMES_HOME, which lives on
# ephemeral /tmp) so entrypoint.sh's seed copy carries it in on every boot,
# same as config.yaml/SOUL.md/skills/ above.
#
# `hermes` on PATH resolves to /opt/hermes/bin/hermes, a privilege-drop shim
# that always execs as the `hermes` user when invoked as root (see its
# source in NousResearch/hermes-agent) -- so this has to run after the
# usermod above remapped that user to uid 1000, the same uid COPY --chown
# gave the seed above; otherwise the plugin install dies with EACCES writing
# into a root-owned directory it can't see past the drop.
#
# --ref pins the install to the hermes-otel-v1.3.0 tag's commit, so a
# rebuild months from now installs the same plugin code rather than
# whatever main has drifted to -- same reasoning as the pinned ARGs below.
# `hermes plugins install` also bootstraps a few HERMES_HOME scaffolding
# paths as a side effect of touching a fresh directory (a plugin-catalog
# cache, a config.yaml backup, empty state dirs); none of that belongs in
# the image -- entrypoint.sh creates the real ones on every boot -- so it's
# deleted right back out. uv (not pip) installs into the base image's venv:
# that venv ships no pip binary, only the interpreter.
ARG HERMES_OTEL_REF=973008ec4f8a4c1f7d9a963177c072964788d163
RUN HERMES_HOME=${HERMES_SEED} hermes plugins install \
        briancaffey/hermes-otel/hermes_otel --ref ${HERMES_OTEL_REF} \
    && uv pip install --python /opt/hermes/.venv/bin/python3 \
        -r ${HERMES_SEED}/plugins/hermes_otel/requirements.txt \
    && rm -rf ${HERMES_SEED}/audio_cache ${HERMES_SEED}/backups \
        ${HERMES_SEED}/cache ${HERMES_SEED}/cron ${HERMES_SEED}/hooks \
        ${HERMES_SEED}/image_cache ${HERMES_SEED}/logs \
        ${HERMES_SEED}/memories ${HERMES_SEED}/pairing \
        ${HERMES_SEED}/sessions \
    && chown -R 1000:1000 ${HERMES_SEED}/plugins

# Extra Python packages for the agent's own use -- list them in
# config/requirements.txt (one per line, standard pip syntax) and uv installs
# them straight into the same venv as Hermes and hermes-otel above
# (/opt/hermes/.venv), so anything imported here is on the interpreter Hermes
# itself runs. Empty by default; `uv pip install -r` on an empty file is a
# no-op, so there's nothing to conditionally skip.
COPY config/requirements.txt /tmp/requirements.txt
RUN uv pip install --python /opt/hermes/.venv/bin/python3 \
        -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

COPY --chown=1000:1000 docker/entrypoint.sh /opt/hermes-workload/entrypoint.sh
RUN chmod 0755 /opt/hermes-workload/entrypoint.sh

# Hermes' own health endpoint. The gateway's api_server serves an
# unauthenticated GET /health (and a richer /health/detailed), which is what
# the workload's readiness probe hits -- no sidecar and no second HTTP
# server. It auto-enables as soon as a usable API_SERVER_KEY exists; the
# entrypoint generates one per boot.
#
# The port stays Hermes' own default, 8642 (API_SERVER_PORT), and
# .datarobot.yaml is what points at it. Only the bind host is overridden:
# the default 127.0.0.1 is unreachable from the kubelet running the probe.
ENV API_SERVER_HOST=0.0.0.0
EXPOSE 8642

# ---------------------------------------------------------------------------
# Agent toolchain
# ---------------------------------------------------------------------------
# The base image already ships node + npm, git, uv/uvx, ripgrep, gcc/g++, make,
# the docker CLI and ffmpeg. Everything below is what it does not.
#
# TARGETARCH is supplied by buildx (amd64 / arm64), so this builds for both the
# workload (amd64) and a local arm64 loop.
USER root
ARG TARGETARCH

# Every download below is `curl | tar`. Under /bin/sh (dash, no pipefail) a
# failed curl is silently swallowed and the build happily produces an image
# with missing binaries. bash + pipefail makes those fail the build instead.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# apt versions are deliberately unpinned: Debian drops old point versions from
# the archive, so pinning them makes the build fail over time rather than stay
# reproducible. The pinned-ARG tools below are the ones that matter.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gnupg openssh-client rsync less file tree \
        jq sqlite3 unzip zip xz-utils bzip2 \
        fd-find bat git-delta git-lfs shellcheck patch diffutils \
        pandoc graphviz poppler-utils \
        build-essential pkg-config \
        procps psmisc iproute2 dnsutils netcat-openbsd \
        gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat \
    && git lfs install --system

# Debian's sqlite3 CLI is compiled against Debian's libsqlite3, but the base
# image ships a newer libsqlite3 (3.53.4) in /usr/local/lib that wins the
# default search order, so the CLI aborts on every invocation with "SQLite
# header and source version mismatch" -- it will not even run `select 1`.
#
# Pin *only this binary* to the library it was built against. The global
# linker path is left alone on purpose: Python's sqlite3 resolves to the newer
# /usr/local build, which is what Hermes' state.db uses for WAL journalling.
RUN set -eux; \
    libdir="$(dirname "$(ls /usr/lib/*-linux-gnu/libsqlite3.so.0 | head -1)")"; \
    printf '#!/bin/sh\nexec env LD_LIBRARY_PATH=%s /usr/bin/sqlite3 "$@"\n' \
        "$libdir" > /usr/local/bin/sqlite3; \
    chmod 0755 /usr/local/bin/sqlite3; \
    /usr/local/bin/sqlite3 :memory: 'select 1;' >/dev/null

# Pinned rather than "latest" so a rebuild months from now produces the same
# image. Bump an ARG to upgrade one tool.
ARG GO_VERSION=1.27.0
ARG GH_VERSION=2.98.0
ARG GLAB_VERSION=1.114.0
ARG YQ_VERSION=4.53.6
ARG TASK_VERSION=3.53.1
ARG KUBECTL_VERSION=1.36.4
ARG HELM_VERSION=4.2.4
ARG PULUMI_VERSION=3.259.0

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) pulumi_arch=x64 ;;  \
        *)     pulumi_arch="${TARGETARCH}" ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
        | tar -C /usr/local -xz; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
        | tar -xz -O "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" > /usr/local/bin/gh; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${TARGETARCH}.tar.gz" \
        | tar -xz -O bin/glab > /usr/local/bin/glab; \
    curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}"; \
    curl -fsSL "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${TARGETARCH}.tar.gz" \
        | tar -xz -O task > /usr/local/bin/task; \
    curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
        | tar -xz -O "linux-${TARGETARCH}/helm" > /usr/local/bin/helm; \
    curl -fsSL "https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-linux-${pulumi_arch}.tar.gz" \
        | tar -xz -C /opt; \
    mv /opt/pulumi /opt/pulumi-sdk; \
    chmod 0755 /usr/local/bin/gh /usr/local/bin/glab /usr/local/bin/yq \
               /usr/local/bin/task /usr/local/bin/kubectl /usr/local/bin/helm

# dr-sync's repo (github.com/datarobot/datarobot-sync) is private, so unlike
# the tools above it can't be curl'd at build time. Vendored under
# vendor/dr-sync/ instead -- see README.md for how to bump it.
COPY vendor/dr-sync/linux_${TARGETARCH}/dr-sync /usr/local/bin/dr-sync
RUN chmod 0755 /usr/local/bin/dr-sync

# The DataRobot CLI -- this project's own deploy tool, so an agent working in
# here can redeploy, read logs and inspect workloads. Its installer resolves
# the latest release; pass a tag to pin.
ARG DR_CLI_VERSION=latest
RUN curl -fsSL -o /tmp/install-dr.sh \
        https://raw.githubusercontent.com/datarobot-oss/cli/main/install.sh \
    && INSTALL_DIR=/usr/local/bin sh /tmp/install-dr.sh "${DR_CLI_VERSION}" \
    && rm -f /tmp/install-dr.sh

# Pulumi's tarball puts `pulumi` and its language plugins at the archive root,
# not under bin/, so /opt/pulumi-sdk itself goes on PATH.
ENV PATH=/usr/local/go/bin:/opt/pulumi-sdk:${PATH}

# Linters/formatters an agent reaches for constantly. ruff installs into a
# read-only image dir with its shim on PATH.
ARG RUFF_VERSION=0.16.4
ARG TYPESCRIPT_VERSION=7.0.2
ARG PRETTIER_VERSION=3.9.6
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
        uv tool install --quiet "ruff==${RUFF_VERSION}" \
    && npm install --global --no-fund --no-audit \
        "typescript@${TYPESCRIPT_VERSION}" "prettier@${PRETTIER_VERSION}" \
    && npm cache clean --force

# --- Making all of that usable on a read-only filesystem -------------------
# Every one of these tools wants a cache, config or state dir, and each would
# default to somewhere outside /tmp -- the difference between `go build`
# working and failing with EROFS at runtime. Kept under /tmp/tools rather than
# inside HERMES_HOME so tool state never collides with Hermes' own layout.
# docker/entrypoint.sh creates the tree on boot.
ENV TOOLS_HOME=/tmp/tools \
    GOPATH=/tmp/tools/go \
    GOMODCACHE=/tmp/tools/go/pkg/mod \
    GOCACHE=/tmp/tools/cache/go-build \
    GOTMPDIR=/tmp \
    npm_config_cache=/tmp/tools/cache/npm \
    UV_CACHE_DIR=/tmp/tools/cache/uv \
    XDG_CACHE_HOME=/tmp/tools/cache \
    XDG_CONFIG_HOME=/tmp/tools/config \
    XDG_DATA_HOME=/tmp/tools/data \
    XDG_STATE_HOME=/tmp/tools/state \
    GH_CONFIG_DIR=/tmp/tools/config/gh \
    GLAB_CONFIG_DIR=/tmp/tools/config/glab \
    PULUMI_HOME=/tmp/tools/pulumi \
    KUBECONFIG=/tmp/tools/config/kube/config \
    HELM_CACHE_HOME=/tmp/tools/cache/helm \
    HELM_CONFIG_HOME=/tmp/tools/config/helm \
    HELM_DATA_HOME=/tmp/tools/data/helm \
    TMPDIR=/tmp
ENV PATH=/tmp/tools/go/bin:${PATH}

# `hermes setup` installed browser-use into ./config/.local as an arm64 venv.
# Re-install it for the image's own architecture when the browser and
# computer_use toolsets are wanted; ~220 MB, so it is off by default.
#
# UV_CACHE_DIR is repinned to /root -- without it, uv would use the
# $TOOLS_HOME/cache/uv set above, baking a root-owned cache into the exact
# path uid 1000 needs to create fresh at runtime (see the HERMES_HOME note
# below for the general version of this trap).
ARG WITH_BROWSER_USE=0
RUN [ "${WITH_BROWSER_USE}" = "1" ] || exit 0; \
    UV_TOOL_DIR=${HERMES_SEED}/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=${HERMES_SEED}/bin \
    UV_CACHE_DIR=/root/.cache/uv \
    uv tool install browser-use \
    && chown -R 1000:1000 ${HERMES_SEED}

# HERMES_HOME has to wait until here, after every RUN that installs a tool.
# uv and npm both cache under $HOME by default (uv's ruff install and npm's
# global typescript/prettier install above ran under the base image's own
# root HOME), and every step up to this point runs as root. Setting
# HOME=/tmp/hermes any earlier bakes root-owned .cache/.npm directories
# straight into the image at the exact path uid 1000 needs to write into at
# runtime -- an unwritable, undeletable landmine, since uid 1000 can't chown,
# chmod, or (thanks to /tmp's sticky bit) even remove a root-owned entry it
# doesn't own. This bit us for real: a resourceAllocation change on the
# workload apparently stopped shadowing /tmp with a fresh mount, and the
# image's own baked content underneath showed through, permission denied on
# every file.
ENV HERMES_HOME=/tmp/hermes \
    HOME=/tmp/hermes \
    HERMES_WRITE_SAFE_ROOT=/tmp/hermes \
    HERMES_LAZY_INSTALL_TARGET=/tmp/hermes/lazy-packages

USER 1000

# Replaces the base image's s6-overlay dispatcher; see docker/entrypoint.sh
# for why s6 cannot bootstrap here.
ENTRYPOINT ["/opt/hermes-workload/entrypoint.sh"]
CMD []
