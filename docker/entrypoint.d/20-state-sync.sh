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
# Persist HERMES_HOME with dr-sync: the helpers, the download before the gateway starts, and the periodic upload loop.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

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
        # Explicit: set -e does not apply inside a function that runs in an || list.
        snapshot_dbs || exit 1
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
    # Skills and plugins are synced, so what the agent learns or adds survives
    # a restart. But the download also put back stored copies of the ones this
    # image ships, which may be older: lay the image's over them again.
    for d in skills plugins; do
        if [ -d "$HERMES_SEED/$d" ]; then
            cp -R "$HERMES_SEED/$d/." "$HERMES_HOME/$d/"
        fi
    done

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
