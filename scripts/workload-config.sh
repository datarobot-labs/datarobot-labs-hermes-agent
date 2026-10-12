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

# Runs `dr workload config` with the given arguments, but keeps the deploying
# user's DATAROBOT_API_TOKEN out of the workload.
#
# `dr dotenv setup` writes the token of whoever is logged in to ./.env, and
# `dr workload config` turns every name in ./.env into a workload variable, so
# left alone the agent would run with that person's long-lived token. The
# workload gets a key of its own instead: the manifest declares
# DATAROBOT_API_TOKEN with `source: api-key`, which the platform fills in.
#
# dr can't be told to skip one name, and `--sync-env` removes an entry .env
# doesn't name, so the command runs against a scratch copy of the project:
# Dockerfile, .env without the token, and .datarobot.yaml without the
# api-key entry. The manifest it writes is copied back with the entry put in.
# ./.env itself is never modified.
#
# Usage: scripts/workload-config.sh <dr workload config arguments>

set -eu

token=DATAROBOT_API_TOKEN
manifest=.datarobot.yaml

[ -f .env ] || { echo "No .env here. Run 'dr start' first." >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp Dockerfile "$work/"
grep -v "^${token}=" .env > "$work/.env" || true

# Strips the api-key form of the token's entry only. Any other form, such as
# a dr-credential an older manifest holds, stays so that --sync-env, which no
# longer finds the name in .env, offers to remove it.
strip_api_key_entry() {
    awk -v name="$token" '
        held != "" {
            if ($0 ~ /^[[:space:]]*source:[[:space:]]*api-key[[:space:]]*$/) { held = ""; next }
            print held; held = ""
        }
        $0 ~ "^[[:space:]]*- name:[[:space:]]*" name "[[:space:]]*$" { held = $0; next }
        { print }
        END { if (held != "") print held }
    ' "$1"
}

# Puts the entry first in the primary container's environmentVars, unless the
# manifest already declares the name in some form.
add_api_key_entry() {
    if grep -qE "^[[:space:]]*- name:[[:space:]]*${token}[[:space:]]*\$" "$1"; then
        cat "$1"
        return
    fi
    awk -v name="$token" '
        !done && /^[[:space:]]*environmentVars:[[:space:]]*$/ {
            print
            match($0, /^[[:space:]]*/)
            indent = substr($0, 1, RLENGTH)
            print indent "  - name: " name
            print indent "    source: api-key"
            done = 1
            next
        }
        { print }
        END { if (!done) exit 3 }
    ' "$1"
}

if [ -f "$manifest" ]; then
    strip_api_key_entry "$manifest" > "$work/$manifest"
    cp "$work/$manifest" "$work/$manifest.before"
fi

dr workload config --dir "$work" "$@"

# Nothing to bring back after a dry run, or a run that changed nothing.
[ -f "$work/$manifest" ] || exit 0
if cmp -s "$work/$manifest" "$work/$manifest.before" 2>/dev/null; then
    exit 0
fi

if ! add_api_key_entry "$work/$manifest" > "$work/$manifest.new"; then
    echo "$manifest has no environmentVars block to add $token to." >&2
    exit 1
fi
cp "$work/$manifest.new" "$manifest"
echo "Updated ./$manifest. (Paths under $work above are the scratch copy dr ran in.)"
