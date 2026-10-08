# Tools image for `tests/run.sh`. Debian trixie is the OS of the Hermes base
# image, so GNU coreutils and dash behave as they do in the workload. Every
# download is pinned by version and checked against a sha256.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bats ca-certificates curl gettext-base git nginx-light procps python3-yaml shellcheck \
    && rm -rf /var/lib/apt/lists/*

ARG HADOLINT_VERSION=v2.15.1
ARG GITLEAKS_VERSION=8.30.1
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) hadolint="hadolint-linux-x86_64"; hadolint_sha="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"; \
             gitleaks="linux_x64"; gitleaks_sha="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;; \
      arm64) hadolint="hadolint-linux-arm64"; hadolint_sha="f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d"; \
             gitleaks="linux_arm64"; gitleaks_sha="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/hadolint "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${hadolint}"; \
    echo "${hadolint_sha}  /usr/local/bin/hadolint" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/hadolint; \
    curl -fsSL -o /tmp/gitleaks.tgz "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${gitleaks}.tar.gz"; \
    echo "${gitleaks_sha}  /tmp/gitleaks.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks; \
    rm /tmp/gitleaks.tgz

# Stand-ins for what docker/entrypoint.sh calls: the tests assert on what it
# calls and with which environment, not on Hermes itself.
COPY fixtures/ /
RUN chmod 0755 /opt/stubs/*

# The virtualenv the entrypoint activates and the hermes-webui server it
# restarts in a loop. Created here because a .venv directory is git-ignored.
RUN mkdir -p /opt/hermes/.venv/bin \
    && printf '#!/bin/sh\nexit 0\n' > /opt/hermes/.venv/bin/python3 \
    && chmod 0755 /opt/hermes/.venv/bin/python3 \
    && : > /opt/hermes/.venv/bin/activate
