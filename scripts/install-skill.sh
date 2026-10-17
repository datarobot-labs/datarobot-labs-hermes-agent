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

# Installs a skill into ./config/skills with `hermes skills install`, run in
# the pinned Hermes image. `dr run install:<skill>` calls it.
#
# The image runs Hermes as its `hermes` user, uid 10000, and refuses any other
# uid. Writing straight into a bind-mounted ./config would then need that
# uid to own the checkout, which a normal Linux clone (owned by the user,
# mode 0755) doesn't. So the container starts as root, copies ./config to the
# image's own /opt/data for Hermes to work in, and replaces ./config/skills
# with the result, owned by the invoking user's uid and gid.
#
# Usage: scripts/install-skill.sh <image> <skill>

set -eu

[ "$#" -eq 2 ] || { echo "usage: $0 <image> <skill>" >&2; exit 2; }
image=$1
skill=$2
config=$(pwd)/config
# Marks the install container, so a later run can tell one is still going.
label=labs-hermes.install-skill

# A run killed between the two renames in the container leaves the previous
# skills in config/.skills.old, no config/skills, and its lock. With no
# install running, put them back and drop the stale lock. With config/skills
# there too, say so rather than pick one.
if [ -d "$config/.skills.old" ]; then
    running=$(docker ps -q --filter "label=$label") \
        || { echo "Could not list running containers to check for another install." >&2; exit 1; }
    if [ -n "$running" ]; then
        echo "Another skill install is running. Try again once it has finished." >&2
        exit 75
    fi
    if [ -d "$config/skills" ]; then
        echo "config/.skills.old is left from an interrupted install, next to config/skills." >&2
        echo "Keep the one you want, delete the other and config/.skills.lock, then try again." >&2
        exit 1
    fi
    mv "$config/.skills.old" "$config/skills"
    rmdir "$config/.skills.lock" 2>/dev/null || true
    echo "Restored config/skills from an interrupted install." >&2
fi

[ -d "$config/skills" ] || { echo "No config/skills here. Run this from the project root." >&2; exit 1; }

# `hermes skills install` asks to confirm. With a terminal on stdin, -t lets
# the caller read its preview and answer. Without one it would read end of
# input, cancel and still exit 0, so then it gets --yes: running this is the
# request to install. --yes skips only the prompt; a blocked scan still needs
# --force, which this never passes.
tty_flag=
install_yes=1
if [ -t 0 ]; then
    tty_flag=-t
    install_yes=
fi

# Runs inside the container, as root. It builds the complete new skills tree
# next to the old one and swaps it in by rename, so an upgrade that removed
# or renamed a skill's files drops the old ones instead of keeping them. If
# the run stops between the two renames, the trap puts the old tree back.
# A lock directory (mkdir is atomic, also on a bind mount) keeps a second
# install from clearing the staging paths while this one owns them. It is
# taken before any cleanup and released last.
# The image's own /opt/data/skills is emptied first, so the result is this
# project's skills plus the install, never skills the image ships with.
# HOST_CONFIG_DIR and HERMES_DATA_DIR are only there so tests can run this
# outside the image.
# shellcheck disable=SC2016 # expanded by the container's shell, not this one
inner='
set -eu
src=${HOST_CONFIG_DIR:-/host-config}
data=${HERMES_DATA_DIR:-/opt/data}
new="$src/.skills.new"
old="$src/.skills.old"
lock="$src/.skills.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo "Another skill install is running (config/.skills.lock exists). If none is," >&2
    echo "remove that directory and try again." >&2
    exit 75
fi
trap "rm -rf \"\$new\"; [ -d \"\$src/skills\" ] || mv \"\$old\" \"\$src/skills\" 2>/dev/null || true; rm -rf \"\$old\"; rmdir \"\$lock\"" EXIT
trap "exit 130" INT TERM HUP
rm -rf "$new" "$old" "$data/skills"
# Hermes needs the config and skills, not what a local hermes setup leaves
# in config: host-arch binaries, runtime state and credential files. The
# exclusions are the ones .dockerignore keeps out of the image, matched at
# the top of config only, so a skill keeps its own bin or cache folder. An
# archive file, not a pipe, so a failed create stops the run.
archive=$(mktemp)
tar -C "$src" --anchored \
    --exclude=./.env --exclude=./auth.json --exclude=./auth.lock \
    --exclude=./bin --exclude=./.local --exclude=./.cua-driver --exclude=./lazy-packages \
    --exclude="./state.db*" --exclude=./logs --exclude=./sessions --exclude=./cache \
    --exclude=./.cache --exclude=./backups --exclude=./audio_cache --exclude=./image_cache \
    --exclude="./config.yaml.bak.*" \
    --exclude=./.skills.new --exclude=./.skills.old --exclude=./.skills.lock \
    -cf "$archive" .
tar -C "$data" -xpf "$archive"
rm -f "$archive"
chown -R hermes:hermes "$data"
hermes skills install ${INSTALL_YES:+--yes} "$1"
cp -a "$data/skills" "$new"
chown -R "$HOST_UID:$HOST_GID" "$new"
mv "$src/skills" "$old"
mv "$new" "$src/skills"
'

docker run -i $tty_flag --rm --user 0:0 --label "$label" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e INSTALL_YES="$install_yes" \
    -v "$config:/host-config" \
    --entrypoint /bin/sh "$image" -c "$inner" sh "$skill"
