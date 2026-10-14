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

# Fails when the installed dr is older than the minimum that
# .datarobot/cli/versions.yaml declares. `dr start` and `dr deps check` make
# the same check, but a task that calls `dr workload` runs without them, and an
# older dr then stops with "unknown command" instead of a fix.
#
# Usage: scripts/check-dr-version.sh [versions file, default .datarobot/cli/versions.yaml]

set -eu

versions=${1:-.datarobot/cli/versions.yaml}

minimum=$(awk '/^dr:/ { found = 1; next } found && /minimum-version:/ { print $2; exit }' "$versions")
if [ -z "$minimum" ]; then
    echo "$versions has no dr minimum-version." >&2
    exit 1
fi

# `dr self version` prints "DataRobot CLI version: v0.14.1".
installed=$(dr self version 2>/dev/null | sed -nE 's/^DataRobot CLI version: v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)
if [ -z "$installed" ]; then
    echo "Can't read the version of dr. Run 'dr self update'." >&2
    exit 1
fi

# Compare each part as a number, so 0.14.10 is newer than 0.14.1.
if ! awk -v have="$installed" -v need="$minimum" 'BEGIN {
    split(have, h, "."); split(need, n, ".")
    for (i = 1; i <= 3; i++) {
        if (h[i] + 0 > n[i] + 0) exit 0
        if (h[i] + 0 < n[i] + 0) exit 1
    }
}'; then
    echo "This needs dr v$minimum or later, and this is v$installed. Run 'dr self update'." >&2
    exit 1
fi
