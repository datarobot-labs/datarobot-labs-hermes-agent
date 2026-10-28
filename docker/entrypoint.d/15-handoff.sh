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
#   starts the gateway again and takes the store over (entrypoint.sh).
# For a few seconds both gateways serve. The reload lays the state handed off
# over what the new one wrote meanwhile, as a boot lays it over the seed: the
# databases and every file the store has are replaced, a file only the new
# pod created is kept. The first rollout onto the handoff, from an old pod
# without the watcher, waits for that pod to stop, up to
# HANDOFF_TIMEOUT_SECONDS.

HERMES_PYTHON="${HERMES_PYTHON:-/opt/hermes/.venv/bin/python3}"
HANDOFF_POLL_SECONDS="${HANDOFF_POLL_SECONDS:-5}"
HANDOFF_TIMEOUT_SECONDS="${HANDOFF_TIMEOUT_SECONDS:-900}"
handoff_marker=.dr-sync-handoff
handoff_flag=/tmp/dr-sync-handed-off
handoff_reload_flag=/tmp/dr-sync-reload
# Set only once this pod has handed off, or is to reload. A container
# restarted in the same pod can keep /tmp (10-seed.sh), and must not take an
# earlier run's flags for its own: it would idle instead of serving.
rm -f "$handoff_flag" "$handoff_reload_flag"
# The generations this pod waits on before it uploads anything (handoff_check).
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

# Their ids. Nothing when the list can't be read: a boot is never held on the API.
handoff_others() {
    handoff_list "$1" | awk '{ print $1 }' || true
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

# The seconds left before the wait's deadline, at least 1: what each call in
# the wait may take, so a hung one can't hold the boot past the deadline.
handoff_left() {
    left=$((handoff_deadline - $(date +%s)))
    [ "$left" -gt 0 ] || left=1
    echo "$left"
}

# At boot, before the download: whether another generation may still write.
# If so, this pod boots on the store's current state, uploads nothing, and
# follows that generation's handoff (handoff_follow).
handoff_check() {
    handoff_enabled || return 0
    handoff_following=$(handoff_others 30)
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
# stops it, and it uploads nothing.
handoff_follow() {
    others=$handoff_following
    handoff_start=$(date +%s)
    handoff_deadline=$((handoff_start + HANDOFF_TIMEOUT_SECONDS))
    while true; do
        if [ -z "$others" ] || handoff_done "$others" "$(handoff_left)"; then
            echo "[entrypoint] state store handed off after $(($(date +%s) - handoff_start))s; reloading it" >&2
            break
        fi
        if [ "$(date +%s)" -ge "$handoff_deadline" ]; then
            # Waiting for good would be worse than the overlap it avoids.
            echo "[entrypoint] Warning: no handoff from $(echo $others) after $(($(date +%s) - handoff_start))s; taking the state store over anyway, and the two may overwrite each other's state" >&2
            break
        fi
        sleep "$HANDOFF_POLL_SECONDS"
        # A list that can't be read changes nothing: an empty one would read
        # as every other generation stopped.
        if list=$(handoff_list "$(handoff_left)"); then
            others=$(echo "$list" | awk '{ print $1 }')
            if echo "$list" | awk '$2 == "running" { found = 1 } END { exit !found }'; then
                handoff_deadline=$(($(date +%s) + HANDOFF_TIMEOUT_SECONDS))
            fi
        fi
    done
    : > "$handoff_reload_flag"
    kill -TERM "$1" 2>/dev/null || true
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
