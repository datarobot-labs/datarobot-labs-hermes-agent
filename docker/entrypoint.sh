#!/bin/sh
# Copyright 2026 DataRobot, Inc. and its affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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

# The boot steps live in entrypoint.d/ and are sourced in this order, so they share one
# shell: variables, functions, background jobs and the trap below all carry across.
# Under set -e a snippet must not end on a failing `cmd && cmd` list: that exits the whole shell.
# shellcheck source-path=SCRIPTDIR
ENTRYPOINT_DIR="${0%/*}/entrypoint.d"
# shellcheck source=entrypoint.d/10-seed.sh
. "$ENTRYPOINT_DIR/10-seed.sh"
# shellcheck source=entrypoint.d/15-handoff.sh
. "$ENTRYPOINT_DIR/15-handoff.sh"
# shellcheck source=entrypoint.d/20-state-sync.sh
. "$ENTRYPOINT_DIR/20-state-sync.sh"
# shellcheck source=entrypoint.d/30-otel.sh
. "$ENTRYPOINT_DIR/30-otel.sh"
# shellcheck source=entrypoint.d/40-gateway-env.sh
. "$ENTRYPOINT_DIR/40-gateway-env.sh"
# shellcheck source=entrypoint.d/50-skills.sh
. "$ENTRYPOINT_DIR/50-skills.sh"
# shellcheck source=entrypoint.d/60-services.sh
. "$ENTRYPOINT_DIR/60-services.sh"

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
#
# A pod that booted while another generation still wrote (15-handoff.sh) runs
# this twice: once on the state it found, and again, after the reload, on the
# state that generation handed off.
stopping=""
trap 'stopping=1; kill -TERM "$gateway_pid" 2>/dev/null || true' TERM INT
while true; do
    hermes gateway run --no-supervise "$@" &
    gateway_pid=$!

    # Once this generation drains, the watcher stops the gateway so the next
    # one can take the state store over; on a pod that follows another
    # generation, the follower stops it to reload what that one hands off.
    handoff_watch_pid=""
    handoff_follow_pid=""
    if [ -n "$handoff_following" ]; then
        handoff_follow "$gateway_pid" &
        handoff_follow_pid=$!
    elif [ -n "$sync_loop_pid" ] && handoff_enabled; then
        handoff_watch "$gateway_pid" &
        handoff_watch_pid=$!
    fi

    # `wait` returns early when a trapped signal arrives; keep waiting until the
    # gateway is really gone, then take its true exit status. The `||` keeps a
    # non-zero status from tripping `set -e`.
    gateway_status=0
    while kill -0 "$gateway_pid" 2>/dev/null; do
        gateway_status=0
        wait "$gateway_pid" || gateway_status=$?
    done

    if [ -n "$handoff_follow_pid" ]; then
        kill "$handoff_follow_pid" 2>/dev/null || true
    fi
    # Not on a stop from the platform, nor on a gateway that exited on its
    # own: a pod that never took the store over leaves it alone.
    if [ -z "$stopping" ] && [ -f "$handoff_reload_flag" ]; then
        rm -f "$handoff_reload_flag"
        handoff_following=""
        echo "[entrypoint] gateway stopped; reloading the state store to take it over" >&2
        webui_pause
        pull_state
        sync_bundled_skills
        webui_resume
        start_sync_loop
        [ -z "$stopping" ] || break
        continue
    fi
    break
done

if [ -n "$handoff_watch_pid" ]; then
    kill "$handoff_watch_pid" 2>/dev/null || true
    # A gateway that exits on its own while this generation drains must still
    # hand off: exiting here would get it restarted, as a second writer.
    if [ ! -f "$handoff_flag" ]; then
        handoff_draining || true
    fi
fi
if [ -n "$sync_loop_pid" ]; then
    # Stops the loop, not a periodic upload already running: killed, it could
    # leave dr-sync's lease held. The final upload waits for it instead.
    kill "$sync_loop_pid" 2>/dev/null || true
    echo "[entrypoint] gateway exited ($gateway_status); running final dr-sync upload" >&2
    if [ -f "$handoff_flag" ]; then
        # Draining, not terminated: there is time to wait and retry, and the
        # next generation waits for exactly this upload, the one carrying the
        # marker, or for this one to stop.
        attempt=1
        until sync_up "${DR_SYNC_FINAL_TIMEOUT:-20}" $((DR_SYNC_UPLOAD_TIMEOUT + 30)) "$handoff_self"; do
            if [ "$attempt" -ge "${HANDOFF_UPLOAD_ATTEMPTS:-5}" ]; then
                rm -rf "${HERMES_HOME:?}/$handoff_marker"
                break
            fi
            echo "[entrypoint] Warning: handoff upload failed (attempt $attempt); retrying" >&2
            sleep $((attempt * HANDOFF_POLL_SECONDS))
            attempt=$((attempt + 1))
        done
    else
        sync_up "${DR_SYNC_FINAL_TIMEOUT:-20}" \
            || echo "[entrypoint] Warning: final dr-sync upload failed" >&2
    fi
fi
if [ -f "$handoff_flag" ]; then
    # Not exit: the platform would start this generation again, and that pod
    # would write to the store the next one now owns. Idle until it is stopped.
    # Without a gateway the platform shows this generation as errored until
    # its drain ends (~8 min on staging); it then stops it as usual.
    if [ -f "$HERMES_HOME/$handoff_marker" ]; then
        echo "[entrypoint] state store handed off; idling until the platform stops this generation" >&2
    else
        echo "[entrypoint] Warning: the handoff upload kept failing, so the next generation waits for this one to stop; idling until then" >&2
    fi
    trap 'exit 0' TERM INT
    while true; do
        sleep 3600 &
        wait $! || true
    done
fi
exit "$gateway_status"
