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

[ -d "$config/skills" ] || { echo "No config/skills here. Run this from the project root." >&2; exit 1; }

# -t only with a terminal on stdin: `hermes skills install` may ask to
# confirm, and docker refuses -t without one.
tty_flag=
[ ! -t 0 ] || tty_flag=-t

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
cp -a "$src/." "$data/"
chown -R hermes:hermes "$data"
hermes skills install "$1"
cp -a "$data/skills" "$new"
chown -R "$HOST_UID:$HOST_GID" "$new"
mv "$src/skills" "$old"
mv "$new" "$src/skills"
'

docker run -i $tty_flag --rm --user 0:0 \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$config:/host-config" \
    --entrypoint /bin/sh "$image" -c "$inner" sh "$skill"
