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
# So the two pods take turns:
# - the old pod watches its own generation (handoff_watch). Once it is
#   draining it stops its gateway, makes its final upload with a marker naming
#   itself (.dr-sync-handoff), and idles until the platform stops it
#   (entrypoint.sh);
# - the new pod, before its download, waits until every other generation has
#   stopped or handed off (handoff_wait). Meanwhile a stand-in answers on its
#   port, so the platform still makes it active, and the old pod drains.
# A redeploy then has about a minute without a gateway instead of minutes of
# two writers. The first rollout onto this code has an old pod without the
# watcher: the new one waits for it to stop, up to HANDOFF_TIMEOUT_SECONDS.

HERMES_PYTHON="${HERMES_PYTHON:-/opt/hermes/.venv/bin/python3}"
HANDOFF_POLL_SECONDS="${HANDOFF_POLL_SECONDS:-5}"
HANDOFF_TIMEOUT_SECONDS="${HANDOFF_TIMEOUT_SECONDS:-900}"
# The port nginx listens on (docker/nginx.conf), held by the stand-in until
# 60-services.sh starts nginx.
HANDOFF_PORT=8642
handoff_marker=.dr-sync-handoff
handoff_flag=/tmp/dr-sync-handed-off
# Set only once this pod has handed off. A container restarted in the same pod
# can keep /tmp (10-seed.sh), and must not take an earlier run's handoff for
# its own: it would idle instead of serving.
rm -f "$handoff_flag"
standin_pid=""
# This pod's generation: the platform names its pods lrs-<proton id>-...
handoff_self=$(hostname | sed -nE 's/^lrs-([0-9a-f]{24})-.*/\1/p')

# Whether this pod can take part: it knows its workload and its generation.
handoff_enabled() {
    [ -n "${DR_SYNC_CATALOG_ID:-}" ] && [ -n "${WORKLOAD_ID:-}" ] && [ -n "$handoff_self" ]
}

# The other generations that may still write: those not stopped. Nothing when
# the list can't be read in $1 seconds: a boot is never held on the API.
handoff_others() {
    timeout --kill-after=2 "$1" "$HERMES_PYTHON" "$ENTRYPOINT_DIR/handoff.py" protons |
        awk -v self="$handoff_self" '$1 != self && $2 != "stopped" { print $1 }' || true
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

handoff_wait() {
    handoff_enabled || return 0
    others=$(handoff_others 30)
    [ -n "$others" ] || return 0
    echo "[entrypoint] generation $(echo $others) may still write the state store; waiting for its handoff before the download" >&2
    "$HERMES_PYTHON" "$ENTRYPOINT_DIR/handoff.py" standin "$HANDOFF_PORT" &
    standin_pid=$!
    handoff_start=$(date +%s)
    handoff_deadline=$((handoff_start + HANDOFF_TIMEOUT_SECONDS))
    while [ "$(date +%s)" -lt "$handoff_deadline" ]; do
        if [ -z "$others" ] || handoff_done "$others" "$(handoff_left)"; then
            echo "[entrypoint] state store handed off after $(($(date +%s) - handoff_start))s" >&2
            return 0
        fi
        sleep "$HANDOFF_POLL_SECONDS"
        others=$(handoff_others "$(handoff_left)")
    done
    if [ -z "$others" ]; then
        echo "[entrypoint] state store handed off after $(($(date +%s) - handoff_start))s" >&2
        return 0
    fi
    # Holding the boot for good would be worse than the overlap it avoids.
    echo "[entrypoint] Warning: no handoff from $(echo $others) after $(($(date +%s) - handoff_start))s; going on, and the two may overwrite each other's state" >&2
}

# Called by 60-services.sh just before nginx takes the port.
handoff_release_port() {
    if [ -n "$standin_pid" ]; then
        kill "$standin_pid" 2>/dev/null || true
        wait "$standin_pid" 2>/dev/null || true
        standin_pid=""
    fi
}

# Run in the background by entrypoint.sh once the gateway is up: when this
# generation starts draining, stop the gateway, so that the final upload is
# this pod's last write and the next generation can take over.
handoff_watch() {
    while kill -0 "$1" 2>/dev/null; do
        sleep "$HANDOFF_POLL_SECONDS"
        status=$(timeout --kill-after=2 30 "$HERMES_PYTHON" "$ENTRYPOINT_DIR/handoff.py" protons 2>/dev/null |
            awk -v self="$handoff_self" '$1 == self { print $2 }' || true)
        case $status in
            draining | stopping)
                echo "[entrypoint] this generation is $status; handing the state store off" >&2
                : > "$handoff_flag"
                kill -TERM "$1" 2>/dev/null || true
                return 0
                ;;
        esac
    done
}
