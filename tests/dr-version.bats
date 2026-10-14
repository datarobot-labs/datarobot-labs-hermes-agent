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

# Behaviour of scripts/check-dr-version.sh: the tasks that call `dr workload`
# refuse a dr older than the minimum in .datarobot/cli/versions.yaml.

setup() {
    WORK=$(mktemp -d)
    mkdir "$WORK/bin"
    printf 'dr:\n  name: DataRobot CLI\n  minimum-version: 0.14.1\n  command: dr self version\n' > "$WORK/versions.yaml"
    # A dr that reports $STUB_VERSION the way `dr self version` does.
    cat > "$WORK/bin/dr" <<'STUB'
#!/bin/sh
[ "$1 $2" = "self version" ] || exit 2
[ -n "${STUB_VERSION:-}" ] || exit 1
echo "DataRobot CLI version: $STUB_VERSION"
STUB
    chmod +x "$WORK/bin/dr"
    PATH="$WORK/bin:$PATH"
}

teardown() {
    rm -rf "$WORK"
}

check() {
    run sh /repo/scripts/check-dr-version.sh "$WORK/versions.yaml"
}

@test "passes when dr is the minimum version" {
    STUB_VERSION=v0.14.1 check
    [ "$status" -eq 0 ]
}

@test "passes when dr is newer, comparing each part as a number" {
    STUB_VERSION=v0.14.10 check
    [ "$status" -eq 0 ]
    STUB_VERSION=v0.15.0 check
    [ "$status" -eq 0 ]
    STUB_VERSION=v1.0.0 check
    [ "$status" -eq 0 ]
}

@test "fails when dr is older, and names both versions and the fix" {
    STUB_VERSION=v0.14.0 check
    [ "$status" -eq 1 ]
    [[ "$output" == *"v0.14.1 or later"* ]]
    [[ "$output" == *"v0.14.0"* ]]
    [[ "$output" == *"dr self update"* ]]
}

@test "fails for the v0.12 release the minimum replaced" {
    STUB_VERSION=v0.12.0 check
    [ "$status" -eq 1 ]
}

@test "fails when dr doesn't report a version" {
    STUB_VERSION= check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Can't read the version of dr"* ]]
}

@test "fails when the versions file has no minimum" {
    printf 'dr:\n  name: DataRobot CLI\n' > "$WORK/versions.yaml"
    STUB_VERSION=v0.14.1 check
    [ "$status" -eq 1 ]
    [[ "$output" == *"no dr minimum-version"* ]]
}

@test "the repo's own minimum is a version this check accepts" {
    minimum=$(awk '/^dr:/ { found = 1; next } found && /minimum-version:/ { print $2; exit }' /repo/.datarobot/cli/versions.yaml)
    STUB_VERSION="v$minimum" run sh /repo/scripts/check-dr-version.sh /repo/.datarobot/cli/versions.yaml
    [ "$status" -eq 0 ]
}
