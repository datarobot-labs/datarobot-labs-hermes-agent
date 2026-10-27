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

# Prints, one per line, the variables .env sets that .datarobot.yaml doesn't
# declare, and exits 1 if there are any: the workload doesn't get them until
# `dr run env` brings them over. `dr start` offers that step when this finds
# something; `dr run doctor` reports it.
#
# Every name counts, empty or `export`ed, as for `dr workload config
# --sync-env`, except DATAROBOT_API_TOKEN: the manifest gives the workload its
# own key under that name, never .env's. Names only: values that differ can't
# be compared here, since dr keeps secrets, the store id among them, as
# credentials it never hands back.
#
# Usage: scripts/env-drift.sh [env file, default .env]
# Exits 2 when it can't read .env or the manifest next to it.

set -eu

env_file=${1:-.env}
manifest=$(dirname "$env_file")/.datarobot.yaml
for f in "$env_file" "$manifest"; do
    [ -r "$f" ] || { echo "Can't read $f." >&2; exit 2; }
done

missing=$(sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$env_file" |
    grep -vx DATAROBOT_API_TOKEN | sort -u |
    while read -r name; do
        grep -qE "^[[:space:]]*- (name: *[\"']?${name}[\"']? *(#.*)?|[{].*name: *[\"']?${name}[\"']? *[,}].*)\$" "$manifest" ||
            echo "$name"
    done)
[ -z "$missing" ] || { echo "$missing"; exit 1; }
