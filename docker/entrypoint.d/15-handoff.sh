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

# shellcheck shell=sh
# The state store's rollout handoff: one writer at a time across a redeploy.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.
#
# Why (measured on staging, LAB-97): a redeploy is rolling, the only strategy
# the platform has. It makes the new generation active as soon as its port
# answers, then lets the old one drain for minutes (~8 min) before it stops
# it, the old pod still running its gateway and uploading. dr-sync compares an
# upload with the store's head, not with what that pod downloaded, so the new
# pod's next upload silently reverted every file the old one had changed in
# the meantime.
#
# So the two pods take turns, and the new one still proves it works first:
# - the new pod, when another generation may still write (handoff_check),
#   boots on the store's current state and serves, but uploads nothing. Its
#   own gateway answers the readiness probe, so an image that can't boot never
#   becomes active, and the old version keeps serving;
# - once it is active, the platform drains the old pod. That one watches its
#   own generation (handoff_watch): it stops its gateway, makes its final
#   upload with a marker naming itself (.dr-sync-handoff), and idles until the
#   platform stops it (entrypoint.sh);
# - the new pod waits for that marker, or for the old pod to stop
#   (handoff_follow). It then stops its gateway, reloads the state handed off,
#   starts the gateway again and takes the store over (entrypoint.sh). Being
#   the active pod by then, it has nginx answer the readiness probe while its
#   gateway is down (handoff_ready_wait).
# For a few seconds both gateways serve. The reload lays the state handed off
# over what the new one wrote meanwhile, as a boot lays it over the seed: the
# databases and every file the store has are replaced, a file only the new
# pod created is kept. The first rollout onto the handoff, from an old pod
# without the watcher, waits for that pod to stop, up to
# HANDOFF_TIMEOUT_SECONDS.

HERMES_PYTHON="${HERMES_PYTHON:-/opt/hermes/.venv/bin/python3}"
HANDOFF_POLL_SECONDS="${HANDOFF_POLL_SECONDS:-5}"
HANDOFF_TIMEOUT_SECONDS="${HANDOFF_TIMEOUT_SECONDS:-900}"
HANDOFF_STOP_SECONDS="${HANDOFF_STOP_SECONDS:-30}"
HANDOFF_READY_SECONDS="${HANDOFF_READY_SECONDS:-120}"
handoff_marker=.dr-sync-handoff
handoff_flag=/tmp/dr-sync-handed-off
handoff_reload_flag=/tmp/dr-sync-reload
# While it exists, nginx answers the readiness probe itself (docker/nginx.conf).
handoff_ready_flag=/tmp/hermes-reloading
# Set only once this pod has handed off, or is to reload. A container
# restarted in the same pod can keep /tmp (10-seed.sh), and must not take an
# earlier run's flags for its own: it would idle instead of serving.
rm -f "$handoff_flag" "$handoff_reload_flag" "$handoff_ready_flag"
# The generations this pod waits on before it uploads anything (handoff_check),
# or "unread" when the list couldn't be read at boot.
handoff_following=""
# This pod's generation: the platform names its pods lrs-<proton id>-...
handoff_self=$(hostname | sed -nE 's/^lrs-([0-9a-f]{24})-.*/\1/p')

# Whether this pod can take part: it knows its workload and its generation.
handoff_enabled() {
    [ -n "${DR_SYNC_CATALOG_ID:-}" ] && [ -n "${WORKLOAD_ID:-}" ] && [ -n "$handoff_self" ]
}

# The other generations that may still write, those not stopped, as
# "<id> <status>" lines read within $1 seconds. Fails when the list can't be read.
handoff_list() {
    handoff_protons=$(timeout --kill-after=2 "$1" "$HERMES_PYTHON" "$ENTRYPOINT_DIR/handoff.py" protons) || return 1
    echo "$handoff_protons" | awk -v self="$handoff_self" 'NF && $1 != self && $2 != "stopped"'
}

# Whether the store's head has a handoff marker from each generation in $1,
# read within $2 seconds.
handoff_done() {
    rm -rf /tmp/dr-sync-handoff-check
    mkdir -p /tmp/dr-sync-handoff-check
    timeout --kill-after=2 "$2" dr-sync download /tmp/dr-sync-handoff-check --prefix "$handoff_marker" \
        >/dev/null 2>&1 || return 1
    for id in $1; do
        grep -qx "$id" "/tmp/dr-sync-handoff-check/$handoff_marker" 2>/dev/null || return 1
    done
}

# What each call in the wait may take: the seconds left before its deadline,
# at most 30 and at least 1, so a hung one can't hold the wait past the
# deadline, nor keep the generation list from being read again.
handoff_left() {
    left=$((handoff_deadline - $(date +%s)))
    [ "$left" -le 30 ] || left=30
    [ "$left" -gt 0 ] || left=1
    echo "$left"
}

# At boot, before the download: whether another generation may still write.
# If so, this pod boots on the store's current state, uploads nothing, and
# follows that generation's handoff (handoff_follow).
handoff_check() {
    handoff_enabled || return 0
    # A list that can't be read is not an empty one: another generation may
    # still write, so this pod follows until a read shows who.
    if ! list=$(handoff_list 30); then
        handoff_following=unread
        echo "[entrypoint] Warning: could not read the generation list; booting on the store's current state, uploading nothing until it can be read" >&2
        return 0
    fi
    handoff_following=$(echo "$list" | awk '{ print $1 }')
    [ -n "$handoff_following" ] || return 0
    echo "[entrypoint] generation $(echo $handoff_following) may still write the state store; booting on its current state, uploading nothing until it hands off" >&2
}

# Run in the background by entrypoint.sh once the gateway is up, on a pod
# handoff_check found following: once every generation it waits on has handed
# off or stopped, it flags the reload and stops the gateway $1, so that
# entrypoint.sh reloads the state handed off and takes the store over.
#
# The timeout counts only once no other generation is running: the platform
# drains the old one only after this one is ready. A pod that never gets
# ready, its gateway wedged, so never takes the store over; the platform
# stops it, and it uploads nothing. Nor does a list that can't be read: who
# else may write is unknown, so neither the end of the wait nor its timeout
# applies until a read succeeds.
handoff_follow() {
    others=$handoff_following
    unread=""
    if [ "$others" = unread ]; then
        unread=1
        others=""
    fi
    handoff_start=$(date +%s)
    handoff_deadline=$((handoff_start + HANDOFF_TIMEOUT_SECONDS))
    while true; do
        if [ -z "$unread" ] && { [ -z "$others" ] || handoff_done "$others" "$(handoff_left)"; }; then
            echo "[entrypoint] state store handed off after $(($(date +%s) - handoff_start))s; reloading it" >&2
            break
        fi
        sleep "$HANDOFF_POLL_SECONDS"
        if list=$(handoff_list "$(handoff_left)"); then
            unread=""
            others=$(echo "$list" | awk '{ print $1 }')
            if echo "$list" | awk '$2 == "running" { found = 1 } END { exit !found }'; then
                handoff_deadline=$(($(date +%s) + HANDOFF_TIMEOUT_SECONDS))
            fi
        else
            # Keeps who else may write (an empty list would read as every
            # other generation stopped), and restarts the timeout: a failed
            # read is no sign that the old one has stopped running.
            handoff_deadline=$(($(date +%s) + HANDOFF_TIMEOUT_SECONDS))
        fi
        # Only here, after the list: the marker check above may have taken
        # until the deadline while another generation still runs.
        if [ -n "$others" ] && [ "$(date +%s)" -ge "$handoff_deadline" ]; then
            # Waiting for good would be worse than the overlap it avoids.
            echo "[entrypoint] Warning: no handoff from $(echo $others) after $(($(date +%s) - handoff_start))s; taking the state store over anyway, and the two may overwrite each other's state" >&2
            break
        fi
    done
    : > "$handoff_reload_flag"
    # This pod is the active one by now: keep it ready while the gateway is
    # down for the reload, or the platform marks it errored and the deploy
    # fails (handoff_ready_wait).
    : > "$handoff_ready_flag"
    handoff_ready_wait &
    kill -TERM "$1" 2>/dev/null || true
    # A gateway that won't stop would keep this pod on the state from before
    # the handoff for good, uploading nothing.
    for _ in $(seq "$HANDOFF_STOP_SECONDS"); do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 1
    done
    echo "[entrypoint] Warning: the gateway did not stop within ${HANDOFF_STOP_SECONDS}s; killing it to reload" >&2
    kill -KILL "$1" 2>/dev/null || true
}

# Run in the background by handoff_follow as it starts the reload: lets the
# readiness probe reach the gateway again as soon as the restarted one answers
# /health itself, or HANDOFF_READY_SECONDS after the reload started, whatever
# holds it up (a download that hangs included), so that a pod whose gateway
# never comes back still fails it. A deadline, not a count of tries: a hung
# gateway takes each try's full --max-time.
handoff_ready_wait() {
    ready_deadline=$(($(date +%s) + HANDOFF_READY_SECONDS))
    while [ "$(date +%s)" -lt "$ready_deadline" ]; do
        sleep 1
        # entrypoint.sh takes the reload flag only once the gateway being
        # stopped has exited: until then, an answer may still be that one's.
        [ ! -f "$handoff_reload_flag" ] || continue
        if curl -sf -o /dev/null --max-time 2 http://127.0.0.1:8643/health; then
            rm -f "$handoff_ready_flag"
            return 0
        fi
    done
    echo "[entrypoint] Warning: the gateway was not back ${HANDOFF_READY_SECONDS}s after the reload started; the readiness probe reaches it again" >&2
    rm -f "$handoff_ready_flag"
}

# Run in the background by entrypoint.sh once the gateway is up: when this
# generation starts draining, stop the gateway, so that the final upload is
# this pod's last write and the next generation can take over.
handoff_watch() {
    while kill -0 "$1" 2>/dev/null; do
        sleep "$HANDOFF_POLL_SECONDS"
        if handoff_draining; then
            kill -TERM "$1" 2>/dev/null || true
            return 0
        fi
    done
}

# Whether this generation is draining or stopping, and if so, sets the
# handed-off flag. entrypoint.sh asks once more when the gateway has exited on
# its own: it may have before the watcher's next poll.
handoff_draining() {
    status=$(timeout --kill-after=2 30 "$HERMES_PYTHON" "$ENTRYPOINT_DIR/handoff.py" protons 2>/dev/null |
        awk -v self="$handoff_self" '$1 == self { print $2 }' || true)
    case $status in
        draining | stopping)
            echo "[entrypoint] this generation is $status; handing the state store off" >&2
            : > "$handoff_flag"
            return 0
            ;;
    esac
    return 1
}
