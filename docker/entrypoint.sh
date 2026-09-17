#!/bin/sh
# Entrypoint for the DataRobot Workload API, replacing the base image's
# s6-overlay dispatcher.
#
# The platform runs this container as uid 1000 on a read-only root filesystem
# with only /tmp writable. s6-overlay cannot bootstrap under either constraint
# -- its preinit wants to fix up /run ownership and gives up as non-root
# ("/run belongs to uid 0 instead of 1000 ... we're lacking the privileges to
# fix it"), which crash-loops the container before Hermes ever starts. Nothing
# Hermes needs is actually supervised: the gateway is a single foreground
# process. So we skip /init and do the handful of things stage2-hook.sh did
# that still apply.
#
# HERMES_HOME points into /tmp, so the seed baked at $HERMES_SEED has to be
# copied in on every boot. That also means state is per-boot: sessions,
# memories and state.db do not survive a restart. Nothing here can change
# that without a writable volume.
set -e

# Hardcoded, not trusted from the image's ENV: this is the one path every
# write in this script (the seed copy) depends on being under /tmp, and
# there's no reason to let anything -- a manifest override, a stale env
# var -- put it anywhere else.
export HERMES_HOME=/tmp/hermes

: "${HERMES_SEED:?HERMES_SEED must be set}"
: "${TOOLS_HOME:?TOOLS_HOME must be set}"

# Names only, never values -- several of these are secrets (LLM_API_KEY,
# SLACK_*_TOKEN, DATAROBOT_API_TOKEN). This is what confirms whether a given
# environmentVars entry actually mounted anything, e.g. whether
# `source: api-key` in .datarobot.yaml produces a DATAROBOT_API_TOKEN.
echo "[entrypoint] environment variable names: $(env | cut -d= -f1 | sort | tr '\n' ' ')" >&2

mkdir -p "$HERMES_HOME"

# Diagnostic for the "cp: Permission denied" crash loop seen 2026-08-21/22:
# every seed file fails to copy into $HERMES_HOME, which worked fine on the
# 2026-08-21 morning boot. Print who we are, the mode of every directory in
# play, AND whether $HERMES_HOME is already non-empty at this point -- a
# CrashLoopBackOff restarts the same pod, and if /tmp survives that restart,
# leftovers from an earlier attempt (not a fresh empty dir) would be the
# actual difference from the working boot.
echo "[entrypoint] id: $(id)" >&2
ls -ld /tmp "$HERMES_HOME" "$HERMES_SEED" >&2 2>&1 || true
echo "[entrypoint] contents of \$HERMES_HOME before the seed copy:" >&2
ls -la "$HERMES_HOME" >&2 2>&1 || true

# The baked seed: config.yaml, SOUL.md, skills/. Read-only in the image, so
# copy rather than symlink -- Hermes rewrites config.yaml in place.
cp -R "$HERMES_SEED/." "$HERMES_HOME/"

# Directories Hermes expects to exist, mirroring stage2-hook.sh's list.
for d in backups cron sessions logs logs/gateways hooks memories skills skins \
         plans workspace home pairing platforms/pairing lazy-packages; do
    mkdir -p "$HERMES_HOME/$d"
done

# Cache/config/state dirs for the bundled toolchain (go, npm, gh, glab, helm,
# kubectl, pulumi, uv). The Dockerfile points every relevant env var at
# $TOOLS_HOME; the dirs themselves have to be made here because /tmp starts
# empty on every boot. Without this, the first `go build` or `gh auth` fails
# on a missing parent rather than on anything meaningful.
mkdir -p "$TOOLS_HOME/go/bin" \
         "$TOOLS_HOME/cache" \
         "$TOOLS_HOME/config/gh" "$TOOLS_HOME/config/glab" \
         "$TOOLS_HOME/config/kube" "$TOOLS_HOME/config/helm" \
         "$TOOLS_HOME/data" "$TOOLS_HOME/state" "$TOOLS_HOME/pulumi"

# HERMES_HOME is per-boot (see top of file); DR_SYNC_CATALOG_ID points dr-sync
# at the Files API container that survives restarts. Pull first, so a
# previous boot's sessions/memories/state.db land before the gateway starts;
# .drsyncignore (baked into the seed above) keeps this from clobbering it
# with a stale copy. Single writer -- this container -- so no lease conflicts
# are expected; a failure here costs continuity, not the boot.
if [ -n "${DR_SYNC_CATALOG_ID:-}" ]; then
    dr-sync download "$HERMES_HOME" \
        || echo "[entrypoint] Warning: dr-sync download failed; starting fresh" >&2

    # Background push loop -- there is no cron/supervisor in this container
    # (see the s6 note at the top), so periodic persistence is just a sleep
    # loop backgrounded before the gateway takes over as PID 1. It dies with
    # the container; the boot-time download above is what actually recovers
    # state, this just keeps the remote copy fresh in between.
    (
        while true; do
            sleep "${DR_SYNC_INTERVAL_SECONDS:-600}"
            dr-sync upload "$HERMES_HOME" \
                || echo "[entrypoint] Warning: dr-sync upload failed; continuing" >&2
        done
    ) &
else
    echo "[entrypoint] DR_SYNC_CATALOG_ID not set; state will not persist across restarts" >&2
fi

# hermes-otel (baked into the seed by the Dockerfile) reads its OTLP backend
# config from $HERMES_HOME/hermes_otel.yaml. That file's DataRobot headers
# carry DATAROBOT_API_TOKEN, a secret, so only a template ships in the seed
# -- rendered into the real file here, once the token exists as a real env
# var, the same reasoning as LLM_API_KEY never landing in a file on disk.
# Skipped when DATAROBOT_ENTITY_ID isn't set (e.g. no Use Case wired up
# yet): hermes-otel then just stays unconfigured rather than exporting
# nowhere with empty auth headers.
if [ -n "${DATAROBOT_ENTITY_ID:-}" ] && [ -f "$HERMES_HOME/hermes_otel.yaml.tmpl" ]; then
    : "${DATAROBOT_OTEL_ENDPOINT:=https://app.datarobot.com/otel}"
    export DATAROBOT_OTEL_ENDPOINT
    envsubst '${DATAROBOT_OTEL_ENDPOINT} ${DATAROBOT_ENTITY_ID} ${DATAROBOT_API_TOKEN}' \
        < "$HERMES_HOME/hermes_otel.yaml.tmpl" > "$HERMES_HOME/hermes_otel.yaml"
else
    echo "[entrypoint] DATAROBOT_ENTITY_ID not set; hermes-otel DataRobot export disabled" >&2
fi

# The gateway's api_server refuses to start without a usable API_SERVER_KEY,
# and that server is what answers the platform's /health probe. It also
# fronts terminal-capable agent routes, so the key is a real credential:
# generate a fresh one per boot rather than persisting or injecting it.
# Nothing outside the container needs it -- the probe path is unauthenticated.
if [ -z "${API_SERVER_KEY:-}" ]; then
    API_SERVER_KEY=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    export API_SERVER_KEY
fi

# Default LLM_API_KEY to the platform-injected DATAROBOT_API_TOKEN (`source:
# api-key` in .datarobot.yaml) rather than requiring a separately managed
# dr-credential: LLM_BASE_URL's default is the DataRobot LLM gateway itself,
# which accepts a normal DataRobot API token, and this one is rotated by the
# platform instead of going stale in a credential nobody remembers to renew.
: "${LLM_API_KEY:=${DATAROBOT_API_TOKEN:-}}"
export LLM_API_KEY

# Some Hermes provider names (e.g. "NVIDIA") are also recognized as
# built-in providers with their own credential lookup by convention --
# <PROVIDER>_API_KEY -- independent of custom_providers[].key_env. Verified
# 2026-08-24: setting LLM_PROVIDER=NVIDIA made Hermes look for
# NVIDIA_API_KEY specifically and ignore our custom_providers entry
# entirely. Alias it dynamically, keyed off whatever LLM_PROVIDER actually
# is, so either lookup path finds the same credential.
if [ -n "${LLM_PROVIDER:-}" ] && [ -n "${LLM_API_KEY:-}" ]; then
    provider_key_var=$(printf '%s' "$LLM_PROVIDER" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')_API_KEY
    eval "export ${provider_key_var}=\"\$LLM_API_KEY\""
fi

# Diagnostic for the 401s seen 2026-08-24: README.md flags `source: api-key`
# as unverified -- confirm DATAROBOT_API_TOKEN is actually non-empty here,
# and that it's actually accepted by the gateway LLM_BASE_URL points at.
# Length and HTTP status only, never the token value.
echo "[entrypoint] DATAROBOT_API_TOKEN length: ${#DATAROBOT_API_TOKEN}; LLM_API_KEY length: ${#LLM_API_KEY}" >&2
if [ -n "${LLM_API_KEY:-}" ] && [ -n "${LLM_BASE_URL:-}" ]; then
    llm_selftest_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "${LLM_BASE_URL}/chat/completions" \
        -H "Authorization: Bearer ${LLM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${LLM_MODEL:-anthropic/claude-opus-4-8}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
        2>/dev/null || echo "curl_failed")
    echo "[entrypoint] LLM gateway self-test: HTTP $llm_selftest_status" >&2
fi

# shellcheck disable=SC1091
. /opt/hermes/.venv/bin/activate

# Bundled skills ship in the install tree and are synced into HERMES_HOME.
# Best-effort: a failure here costs skills, not the bot.
if [ -d /opt/hermes/skills ]; then
    python /opt/hermes/tools/skills_sync.py \
        || echo "[entrypoint] Warning: skills_sync.py failed; continuing" >&2
fi

cd "$HERMES_HOME"

# Hermes' own ${VAR} substitution in config.yaml resolves correctly for a
# fresh `hermes config get` read, but NOT for the long-running gateway's
# conversation loop -- verified 2026-08-24: a live chat completion kept
# sending the literal string "${LLM_MODEL}" upstream, 404ing against the
# DataRobot LLM gateway, even though `hermes config get model` showed it
# fully resolved. custom_providers[].base_url isn't templated at all: it's
# a plain literal that never tracked LLM_BASE_URL to begin with.
# HERMES_MODEL -- Hermes' own documented process-level model override --
# doesn't reach this path either; the docs scope it to the cron scheduler
# only, and it was verified not to affect gateway chat completions.
# Resolve both through Hermes' own `config set` instead, so LLM_MODEL/
# LLM_BASE_URL still fully control this at every boot with zero commits to
# config.yaml -- just resolved by us instead of Hermes' broken templating.
# LLM_API_KEY is deliberately untouched here: its ${VAR} substitution and
# custom_providers[].key_env both provably work already.
hermes config set model.default "$LLM_MODEL" >&2
hermes config set custom_providers.0.base_url "$LLM_BASE_URL" >&2

# No s6 to hand off to, so --no-supervise is the only correct mode: the
# gateway is the container's main process and its exit is the container's
# exit, which is what lets Kubernetes restart a wedged bot.
exec hermes gateway run --no-supervise "$@"
