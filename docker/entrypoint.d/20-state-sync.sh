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
# A periodic upload's bound: one that hangs would otherwise hold the lock, and
# with it the handoff's final upload, for good.
DR_SYNC_UPLOAD_TIMEOUT="${DR_SYNC_UPLOAD_TIMEOUT:-600}"

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
        # A new file renamed into place: on a reload (entrypoint.sh), a process
        # still holding the old one open keeps it whole.
        cp -f "$DB_SNAPSHOTS/$rel" "$dest.restore" && mv -f "$dest.restore" "$dest"
        echo "[entrypoint] restored database $rel" >&2
    done
}

# One upload. The flock serialises the periodic loop against the final
# shutdown upload, so they can't contend for dr-sync's lease. $1 is an
# optional timeout (seconds) for the dr-sync call; 0/unset means none. $2 is
# how long to wait for the lock, 5 s by default: short on a shutdown, and
# timeout escalates to SIGKILL, so the upload can't outlive the pod's
# termination grace period. $3, on a handoff, is this generation's id: the
# marker is written under the lock, after the snapshots, so no upload but this
# one can carry it (15-handoff.sh).
sync_up() {
    (
        flock -w "${2:-5}" 9 || { echo "[entrypoint] Warning: could not get the sync lock" >&2; exit 1; }
        # Explicit: set -e does not apply inside a function that runs in an || list.
        snapshot_dbs || exit 1
        if [ -n "${3:-}" ]; then
            # A fresh file, whatever the store left at that path: a directory
            # would fail the write, and a symlink would take it elsewhere.
            rm -rf "${HERMES_HOME:?}/$handoff_marker"
            echo "$3" > "$HERMES_HOME/$handoff_marker" || exit 1
        fi
        timeout --kill-after=2 "${1:-0}" dr-sync upload "$HERMES_HOME" \
            --keep-generations 144 \
            --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm'
    ) 9>/tmp/.dr-sync.lock
}

# The download goes into an empty directory, then into $HERMES_HOME. The
# seed is already there, and dr-sync fails a download that would write a
# stored path over one of another type (a file where the image ships a
# directory, or the reverse): every boot would stop. An empty directory has
# nothing to conflict with.
stage=/tmp/dr-sync-stage
download_state() {
    rm -rf "$stage"
    mkdir -p "$stage"
    # dr-sync reads the ignore file from the directory it downloads into.
    if [ -f "$HERMES_HOME/.drsyncignore" ]; then
        cp "$HERMES_HOME/.drsyncignore" "$stage/"
    fi
    attempt=1
    delay=5
    while true; do
        if dr-sync download "$stage"; then
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

# A directory, and not a symlink to one.
is_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

# Moves the download into $HERMES_HOME, which holds the image's seed. A stored
# path of another type than the one there stays out: the image wins. Moved,
# not copied: /tmp is the only writable filesystem, and a copy would hold the
# whole state twice for a moment.
merge_state() {
    (cd "$stage" && find . -mindepth 1) > /tmp/dr-sync-stage.list || return 1
    # Parents come before their entries, so a directory moved whole takes its
    # entries with it, and a directory both sides have is merged entry by entry.
    while IFS= read -r p; do
        p=${p#./}
        if [ ! -e "$stage/$p" ] && [ ! -L "$stage/$p" ]; then
            continue # moved, or dropped, with its directory
        fi
        if [ ! -e "$HERMES_HOME/$p" ] && [ ! -L "$HERMES_HOME/$p" ]; then
            mv "$stage/$p" "$HERMES_HOME/$p" || return 1
        # A symlink never replaces the image's path: over a file, the overlay
        # below would write through it to wherever it points, and a dangling
        # one over a directory would fail the merge.
        elif [ -L "$stage/$p" ]; then
            echo "[entrypoint] Warning: the store has a symlink at $p, where the image has a file or directory; keeping the image's" >&2
            rm -f "$stage/$p"
        elif is_dir "$stage/$p"; then
            if ! is_dir "$HERMES_HOME/$p"; then
                echo "[entrypoint] Warning: the store has a directory at $p, where the image has a file; keeping the image's" >&2
                rm -rf "${stage:?}/$p"
            fi
        elif is_dir "$HERMES_HOME/$p"; then
            echo "[entrypoint] Warning: the store has a file at $p, where the image has a directory; keeping the image's" >&2
            rm -f "$stage/$p"
        else
            # A rename: it replaces the path itself, never writing through it.
            mv -f "$stage/$p" "$HERMES_HOME/$p" || return 1
        fi
    done < /tmp/dr-sync-stage.list
    rm -rf "$stage" /tmp/dr-sync-stage.list
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
#
# pull_state runs at boot, and again on a rollout's reload (entrypoint.sh).
pull_state() {
    if ! download_state; then
        echo "[entrypoint] FATAL: dr-sync download failed after $DR_SYNC_DOWNLOAD_ATTEMPTS attempts; refusing to start with empty state" >&2
        exit 1
    fi
    # Half a merge is no better than none: an upload would then shrink the store.
    if ! merge_state; then
        echo "[entrypoint] FATAL: could not move the downloaded state into $HERMES_HOME; refusing to start with part of it" >&2
        exit 1
    fi
    restore_dbs
    # Skills and plugins are synced, so what the agent learns or adds survives
    # a restart. The download also brought back what earlier images shipped:
    # older copies of this image's skills and plugins, and ones this image
    # dropped. .dr-sync-shipped, uploaded with the rest, lists every file any
    # image shipped to this store: those this one doesn't go, then this image's
    # are laid over the rest. Every one, not just the last image's: an upload
    # keeps a file the store has after it's deleted here, so a dropped skill
    # comes back with every download and has to go every time. Hermes' bundled
    # skills are skills_sync.py's (50-skills.sh).
    shipped="$HERMES_HOME/.dr-sync-shipped"
    (cd "$HERMES_SEED" && find skills plugins -type f 2>/dev/null) | sort > /tmp/dr-sync-shipped
    if [ -f "$shipped" ]; then
        grep -vxF -f /tmp/dr-sync-shipped "$shipped" | while IFS= read -r f; do
            # Only a path under skills/ or plugins/: the list came from the store.
            case $f in skills/?* | plugins/?*) ;; *) continue ;; esac
            case $f in *..*) continue ;; esac
            rm -f "$HERMES_HOME/$f"
            # Its directories too, once empty, up to skills/ or plugins/.
            dir=${f%/*}
            while [ "$dir" != skills ] && [ "$dir" != plugins ] &&
                rmdir "$HERMES_HOME/$dir" 2>/dev/null; do
                dir=${dir%/*}
            done
        done
    fi
    # The overlay replaces the hub's lock with the image's: move the stored one
    # aside, to merge back the records of skills the agent installed. A rename,
    # so it neither reads the file nor needs room for a copy, and a failure
    # only costs those records.
    lock=skills/.hub/lock.json
    stored_lock=
    if [ -f "$HERMES_HOME/$lock" ] && [ -f "$HERMES_SEED/$lock" ]; then
        if mv -f "$HERMES_HOME/$lock" /tmp/dr-sync-hub-lock.json; then
            stored_lock=/tmp/dr-sync-hub-lock.json
        else
            echo "[entrypoint] Warning: could not set the hub's stored lock aside; skills installed at runtime keep their files, not their hub records" >&2
        fi
    fi
    for d in skills plugins; do
        if [ -d "$HERMES_SEED/$d" ]; then
            cp -R "$HERMES_SEED/$d/." "$HERMES_HOME/$d/"
        fi
    done
    if [ -n "$stored_lock" ]; then
        /opt/hermes/.venv/bin/python3 "$ENTRYPOINT_DIR/hub-lock.py" \
            "$stored_lock" "$HERMES_HOME/$lock" "$HERMES_HOME/skills" ||
            echo "[entrypoint] Warning: could not merge the hub's lock; skills installed at runtime keep their files, not their hub records" >&2
        rm -f "$stored_lock"
    fi
    if [ -f "$shipped" ]; then
        sort -u "$shipped" /tmp/dr-sync-shipped > /tmp/dr-sync-shipped.all
        mv /tmp/dr-sync-shipped.all "$shipped"
    else
        cp /tmp/dr-sync-shipped "$shipped"
    fi
}

# Background push loop -- there is no cron/supervisor in this container
# (see the s6 note at the top), so periodic persistence is a sleep loop
# backgrounded before the gateway starts. The gateway is NOT exec'd (see
# the end of entrypoint.sh), so the SIGTERM handler there can stop this loop
# and run one last upload before the container exits.
start_sync_loop() {
    (
        while true; do
            sleep "${DR_SYNC_INTERVAL_SECONDS:-600}"
            sync_up "$DR_SYNC_UPLOAD_TIMEOUT" || echo "[entrypoint] Warning: dr-sync upload failed; continuing" >&2
        done
    ) &
    sync_loop_pid=$!
}

sync_loop_pid=""
if [ -n "${DR_SYNC_CATALOG_ID:-}" ]; then
    # During a rollout the previous generation may still write: this pod then
    # boots on the store as it is, and uploads only once it has taken the
    # store over (15-handoff.sh).
    handoff_check
    pull_state
    [ -n "$handoff_following" ] || start_sync_loop
else
    echo "[entrypoint] DR_SYNC_CATALOG_ID not set; state will not persist across restarts" >&2
fi
