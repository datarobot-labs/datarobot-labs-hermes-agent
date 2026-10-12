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
# image's own /opt/data for Hermes to work in, and copies the result back
# into ./config/skills owned by the invoking user's uid and gid.
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

# shellcheck disable=SC2016 # expanded by the container's shell, not this one
docker run -i $tty_flag --rm --user 0:0 \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$config:/host-config" \
    --entrypoint /bin/sh "$image" -c '
        set -eu
        cp -a /host-config/. /opt/data/
        chown -R hermes:hermes /opt/data
        hermes skills install "$1"
        cp -a /opt/data/skills/. /host-config/skills/
        chown -R "$HOST_UID:$HOST_GID" /host-config/skills
    ' sh "$skill"
