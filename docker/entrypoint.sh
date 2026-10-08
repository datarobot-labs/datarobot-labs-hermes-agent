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

# One greppable line per container start (`dr workload logs | grep ' boot '`),
# so a pod move is visible in the logs. hostname is the pod name.
echo "[entrypoint] boot $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname) dr_sync_catalog=${DR_SYNC_CATALOG_ID:-none}" >&2

# --- State sync helpers (see the dr-sync block below for the why) -----------
#
# Hermes keeps live SQLite databases (state.db, cron/*.db, kanban.db, ...)
# open in WAL mode under $HERMES_HOME. Uploading the .db, -wal and -shm files
# as three independent reads can capture them at different instants, and a
# restore of a mismatched trio silently drops whatever the WAL held. So live
# databases are never uploaded; instead each tick takes a consistent
# `sqlite3 .backup` copy of every one into $DB_SNAPSHOTS (as <relpath>.snap)
# and those copies are what travel.
DB_SNAPSHOTS="$HERMES_HOME/.dr-sync-snapshots"
DR_SYNC_DOWNLOAD_ATTEMPTS="${DR_SYNC_DOWNLOAD_ATTEMPTS:-5}"

snapshot_dbs() {
    find "$HERMES_HOME" \
        \( -path "$DB_SNAPSHOTS" -o -path "$HERMES_HOME/skills" \
           -o -path "$HERMES_HOME/plugins" -o -path "$HERMES_HOME/lazy-packages" \
           -o -path "$HERMES_HOME/cache" -o -path "$HERMES_HOME/logs" \) -prune \
        -o -type f -name '*.db' -print |
    {
    unprotected=0
    while IFS= read -r db; do
        snap="$DB_SNAPSHOTS/${db#"$HERMES_HOME"/}.snap"
        mkdir -p "$(dirname "$snap")"
        # Back up to a temp name, then rename: a failed backup must not
        # replace the previous good snapshot with a truncated one.
        if sqlite3 "$db" ".backup '$snap.tmp'"; then
            mv -f "$snap.tmp" "$snap"
        else
            rm -f "$snap.tmp"
            if [ ! -f "$snap" ]; then
                # Live .db files are never uploaded, so with no earlier
                # snapshot this generation would carry no copy of $db.
                echo "[entrypoint] Error: snapshot of $db failed and no previous snapshot exists" >&2
                unprotected=1
                continue
            fi
            echo "[entrypoint] Warning: snapshot of $db failed; keeping the previous snapshot" >&2
        fi
    done
    # Non-zero aborts the upload so a generation without databases is never
    # published as the latest.
    [ "$unprotected" -eq 0 ]
    }
}

# Put the downloaded snapshots back at their real paths. A -wal/-shm that
# came down alongside (legacy uploads, from before snapshots existed) belongs
# to the OLD main file, so it is removed rather than paired with the snapshot.
# With no snapshots yet (first boot after this shipped) the legacy live files
# that were downloaded are left exactly as they are.
restore_dbs() {
    [ -d "$DB_SNAPSHOTS" ] || return 0
    ( cd "$DB_SNAPSHOTS" && find . -type f -name '*.db.snap' -print ) |
    while IFS= read -r rel; do
        rel="${rel#./}"
        dest="$HERMES_HOME/${rel%.snap}"
        mkdir -p "$(dirname "$dest")"
        rm -f "$dest-wal" "$dest-shm"
        cp -f "$DB_SNAPSHOTS/$rel" "$dest"
        echo "[entrypoint] restored database $rel" >&2
    done
}

# One upload. The flock serialises the periodic loop against the final
# shutdown upload, so they can't contend for dr-sync's lease. $1 is an
# optional timeout (seconds) for the dr-sync call; 0/unset means none. The
# lock wait is short and timeout escalates to SIGKILL so the shutdown upload
# can't outlive the pod's termination grace period.
sync_up() {
    (
        flock -w 5 9 || { echo "[entrypoint] Warning: could not get the sync lock" >&2; exit 1; }
        snapshot_dbs
        timeout --kill-after=2 "${1:-0}" dr-sync upload "$HERMES_HOME" \
            --keep-generations 144 \
            --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm'
    ) 9>/tmp/.dr-sync.lock
}

download_state() {
    attempt=1
    delay=5
    while true; do
        if dr-sync download "$HERMES_HOME"; then
            return 0
        fi
        if [ "$attempt" -ge "$DR_SYNC_DOWNLOAD_ATTEMPTS" ]; then
            return 1
        fi
        echo "[entrypoint] dr-sync download failed (attempt $attempt/$DR_SYNC_DOWNLOAD_ATTEMPTS); retrying in ${delay}s" >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}

# Names only, never values -- several of these are secrets (LLM_API_KEY,
# SLACK_*_TOKEN, DATAROBOT_API_TOKEN). This is what confirms whether a given
# environmentVars entry actually mounted anything, e.g. whether
# `source: api-key` in .datarobot.yaml produces a DATAROBOT_API_TOKEN.
# NUL-delimited so a multi-line value (the GITHUB_PRIVATE_KEY PEM) stays one
# record and only its name is printed.
echo "[entrypoint] environment variable names: $(env -0 | cut -z -d= -f1 | sort -z | tr '\0' ' ')" >&2

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
         plans workspace home pairing platforms/pairing lazy-packages webui; do
    mkdir -p "$HERMES_HOME/$d"
done

# nginx's pid file and temp dirs (see docker/nginx.conf) -- /tmp starts
# empty on every boot, same reasoning as the loop above.
mkdir -p /tmp/nginx

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
# with a stale copy.
#
# A failed download is FATAL (after retries), not "start fresh": booting with
# empty state would let the push loop below overwrite the good remote
# state.db/sessions/memories with an empty copy within one interval. Exiting
# lets Kubernetes retry the pod instead. An empty remote (first deploy) is a
# successful download of nothing, so that still boots.
sync_loop_pid=""
if [ -n "${DR_SYNC_CATALOG_ID:-}" ]; then
    if ! download_state; then
        echo "[entrypoint] FATAL: dr-sync download failed after $DR_SYNC_DOWNLOAD_ATTEMPTS attempts; refusing to start with empty state" >&2
        exit 1
    fi
    restore_dbs

    # Background push loop -- there is no cron/supervisor in this container
    # (see the s6 note at the top), so periodic persistence is a sleep loop
    # backgrounded before the gateway starts. The gateway is NOT exec'd (see
    # the end of this file), so the SIGTERM handler there can stop this loop
    # and run one last upload before the container exits.
    (
        while true; do
            sleep "${DR_SYNC_INTERVAL_SECONDS:-600}"
            sync_up || echo "[entrypoint] Warning: dr-sync upload failed; continuing" >&2
        done
    ) &
    sync_loop_pid=$!
else
    echo "[entrypoint] DR_SYNC_CATALOG_ID not set; state will not persist across restarts" >&2
fi

# hermes-otel (baked into the seed by the Dockerfile) reads its OTLP backend
# config from $HERMES_HOME/hermes_otel.yaml. That file's DataRobot headers
# carry DATAROBOT_API_TOKEN, a secret, so only a template ships in the seed
# -- rendered into the real file here, once the token exists as a real env
# var, the same reasoning as LLM_API_KEY never landing in a file on disk.
# A workload's traces live under its own "workload-<id>" entity -- the same
# service.name the platform's gateway spans use -- so default the OTel entity
# to this workload when one wasn't set explicitly (e.g. to a Use Case). The
# platform injects WORKLOAD_ID at runtime, so this needs no manual wiring.
if [ -z "${DATAROBOT_ENTITY_ID:-}" ] && [ -n "${WORKLOAD_ID:-}" ]; then
    DATAROBOT_ENTITY_ID="workload-${WORKLOAD_ID}"
fi

# Derive the OTel endpoint from the API endpoint so export follows whichever
# install this runs on (app, staging, on-prem) instead of a pinned host --
# the same derivation DataRobot's own dr_otel_config does: trim trailing
# slashes, strip the /api/v2 suffix, then add /otel. The trailing-slash trim
# matters: without it a "https://host/api/v2/" endpoint would not match the
# /api/v2 suffix and would yield "/api/v2//otel".
if [ -z "${DATAROBOT_OTEL_ENDPOINT:-}" ] && [ -n "${DATAROBOT_ENDPOINT:-}" ]; then
    _dr_base="$DATAROBOT_ENDPOINT"
    while [ "$_dr_base" != "${_dr_base%/}" ]; do _dr_base="${_dr_base%/}"; done
    DATAROBOT_OTEL_ENDPOINT="${_dr_base%/api/v2}/otel"
    unset _dr_base
fi

# Enable export only when everything a successful upload needs is present: an
# entity to attribute traces to, the API token the auth header carries, and an
# endpoint. Export is on by default now (the entity derives from WORKLOAD_ID),
# so guarding on the token matters -- without it every trace, metric and log
# POST would 401 and flood the logs for every workload, not just one that had
# opted in. DATAROBOT_API_TOKEN is platform-injected; see the Secrets section.
if [ -n "${DATAROBOT_ENTITY_ID:-}" ] \
    && [ -n "${DATAROBOT_API_TOKEN:-}" ] \
    && [ -n "${DATAROBOT_OTEL_ENDPOINT:-}" ] \
    && [ -f "$HERMES_HOME/hermes_otel.yaml.tmpl" ]; then
    export DATAROBOT_ENTITY_ID DATAROBOT_OTEL_ENDPOINT
    # envsubst needs the literal variable names, so the single quotes are intended.
    # shellcheck disable=SC2016
    envsubst '${DATAROBOT_OTEL_ENDPOINT} ${DATAROBOT_ENTITY_ID} ${DATAROBOT_API_TOKEN}' \
        < "$HERMES_HOME/hermes_otel.yaml.tmpl" > "$HERMES_HOME/hermes_otel.yaml"
    echo "[entrypoint] hermes-otel export enabled: entity=${DATAROBOT_ENTITY_ID} endpoint=${DATAROBOT_OTEL_ENDPOINT}" >&2
else
    echo "[entrypoint] hermes-otel export disabled: need an entity (DATAROBOT_ENTITY_ID or WORKLOAD_ID), DATAROBOT_API_TOKEN, and an OTel endpoint (DATAROBOT_OTEL_ENDPOINT or DATAROBOT_ENDPOINT)" >&2
fi

# The gateway's api_server refuses to start without a usable API_SERVER_KEY,
# and that server is what answers the platform's /health probe. The key is
# a real credential:
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

# hermes-webui and nginx (docker/nginx.conf) run backgrounded, same pattern
# as the dr-sync push loop above -- the gateway below is what this script
# waits on, since ITS exit is what should end/restart the container. A crash in
# either background process costs the UI until the next boot, not the bot;
# each gets its own restart loop so a transient failure doesn't wedge it
# for the rest of the container's life.
#
# Explicit venv path (not relying on the `activate` above) because these
# are separate long-running processes, not sourced into this shell.
(
    while true; do
        /opt/hermes/.venv/bin/python3 /opt/hermes-webui/server.py \
            || echo "[entrypoint] Warning: hermes-webui exited; restarting in 2s" >&2
        sleep 2
    done
) &

(
    while true; do
        nginx -c /opt/hermes-workload/nginx.conf \
            || echo "[entrypoint] Warning: nginx exited; restarting in 2s" >&2
        sleep 2
    done
) &

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
# gateway's exit is the container's exit, which is what lets Kubernetes
# restart a wedged bot.
#
# Not `exec`'d: this shell stays PID 1 so it can flush state on the way out.
# Kubernetes moving a pod sends SIGTERM to PID 1; with the gateway as PID 1
# nothing was left to push the last (up to DR_SYNC_INTERVAL_SECONDS) of
# sessions/memories. Now SIGTERM is forwarded to the gateway, and once it has
# exited cleanly one final upload runs, bounded by DR_SYNC_FINAL_TIMEOUT so it
# stays inside the pod's termination grace period (30s by default).
hermes gateway run --no-supervise "$@" &
gateway_pid=$!
trap 'kill -TERM "$gateway_pid" 2>/dev/null || true' TERM INT

# `wait` returns early when a trapped signal arrives; keep waiting until the
# gateway is really gone, then take its true exit status. The `||` keeps a
# non-zero status from tripping `set -e`.
gateway_status=0
while kill -0 "$gateway_pid" 2>/dev/null; do
    gateway_status=0
    wait "$gateway_pid" || gateway_status=$?
done

if [ -n "$sync_loop_pid" ]; then
    kill "$sync_loop_pid" 2>/dev/null || true
    echo "[entrypoint] gateway exited ($gateway_status); running final dr-sync upload" >&2
    sync_up "${DR_SYNC_FINAL_TIMEOUT:-20}" \
        || echo "[entrypoint] Warning: final dr-sync upload failed" >&2
fi
exit "$gateway_status"
