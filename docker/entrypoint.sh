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

: "${HERMES_HOME:?HERMES_HOME must be set}"
: "${HERMES_SEED:?HERMES_SEED must be set}"
: "${TOOLS_HOME:?TOOLS_HOME must be set}"

mkdir -p "$HERMES_HOME"

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

# The gateway's api_server refuses to start without a usable API_SERVER_KEY,
# and that server is what answers the platform's /health probe. It also
# fronts terminal-capable agent routes, so the key is a real credential:
# generate a fresh one per boot rather than persisting or injecting it.
# Nothing outside the container needs it -- the probe path is unauthenticated.
if [ -z "${API_SERVER_KEY:-}" ]; then
    API_SERVER_KEY=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    export API_SERVER_KEY
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

# No s6 to hand off to, so --no-supervise is the only correct mode: the
# gateway is the container's main process and its exit is the container's
# exit, which is what lets Kubernetes restart a wedged bot.
exec hermes gateway run --no-supervise "$@"
