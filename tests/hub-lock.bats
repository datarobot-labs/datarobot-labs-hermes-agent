#!/usr/bin/env bats
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

# Behaviour of docker/entrypoint.d/hub-lock.py: the image's hub records win,
# a stored record survives only while its skill is in skills/, and a lock it
# can't read leaves the image's as it was.

setup() {
    WORK=$(mktemp -d)
    mkdir -p "$WORK/skills/.hub" "$WORK/skills/creative/ascii-art" "$WORK/skills/runtime/learned"
    cat > "$WORK/skills/.hub/lock.json" <<'JSON'
{"version": 1, "installed": {
  "ascii-art": {"install_path": "creative/ascii-art", "content_hash": "sha256:new"}}}
JSON
    chmod 644 "$WORK/skills/.hub/lock.json"
    cat > "$WORK/stored.json" <<'JSON'
{"version": 1, "installed": {
  "ascii-art": {"install_path": "creative/ascii-art", "content_hash": "sha256:old"},
  "learned": {"install_path": "runtime/learned"},
  "pruned": {"install_path": "gone/pruned"},
  "escape": {"install_path": "../outside"},
  "odd": "not a record"}}
JSON
    mkdir -p "$WORK/outside"
}

teardown() {
    rm -rf "$WORK"
}

merge() {
    run python3 /repo/docker/entrypoint.d/hub-lock.py "$1" "$WORK/skills/.hub/lock.json" "$WORK/skills"
}

record() {
    python3 -c 'import json, sys
lock = json.load(open(sys.argv[1]))["installed"]
print(json.dumps(lock.get(sys.argv[2])))' "$WORK/skills/.hub/lock.json" "$1"
}

@test "a runtime skill keeps its record, and the image's record wins over the stored one" {
    merge "$WORK/stored.json"
    [ "$status" -eq 0 ]
    [ "$(record learned)" = '{"install_path": "runtime/learned"}' ]
    [ "$(record ascii-art)" = '{"install_path": "creative/ascii-art", "content_hash": "sha256:new"}' ]
    [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/skills/.hub/lock.json")" = 1 ]
}

@test "a record whose skill is gone, or points outside skills/, is dropped" {
    merge "$WORK/stored.json"
    [ "$status" -eq 0 ]
    [ "$(record pruned)" = null ]
    [ "$(record escape)" = null ]
    [ "$(record odd)" = null ]
}

@test "the merged lock keeps the image lock's permissions, and nothing is left beside it" {
    merge "$WORK/stored.json"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$WORK/skills/.hub/lock.json")" = 644 ]
    [ "$(ls -A "$WORK/skills/.hub")" = lock.json ]
}

@test "a stored lock it can't read leaves the image's lock as it was" {
    cp "$WORK/skills/.hub/lock.json" "$WORK/before"
    for bad in '{not json' '[]' '{"installed": []}'; do
        printf '%s' "$bad" > "$WORK/bad.json"
        merge "$WORK/bad.json"
        [ "$status" -eq 1 ]
        [[ "$output" == *"hub-lock.py:"* ]]
        cmp "$WORK/before" "$WORK/skills/.hub/lock.json"
    done
}
