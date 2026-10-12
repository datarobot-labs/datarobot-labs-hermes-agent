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

# How scripts/install-skill.sh runs the Hermes image. docker is a stub that
# records its arguments, one per line; the image itself isn't run here.

setup() {
    WORK=$(mktemp -d)
    mkdir -p "$WORK/project/config/skills" "$WORK/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$DOCKER_ARGS"\n' > "$WORK/bin/docker"
    chmod +x "$WORK/bin/docker"
}

teardown() {
    rm -rf "$WORK"
}

install_skill() {
    cd "$WORK/project"
    PATH="$WORK/bin:$PATH" DOCKER_ARGS="$WORK/args" \
        run sh /repo/scripts/install-skill.sh registry.example.com/hermes@sha256:abc "$@"
}

@test "runs as root with the caller's ids, binding ./config by absolute path" {
    install_skill official/creative/ascii-art
    [ "$status" -eq 0 ]
    grep -qx -- '--user' "$WORK/args"
    grep -qx -- '0:0' "$WORK/args"
    grep -qx -- "HOST_UID=$(id -u)" "$WORK/args"
    grep -qx -- "HOST_GID=$(id -g)" "$WORK/args"
    grep -qx -- "$WORK/project/config:/host-config" "$WORK/args"
    grep -qx -- 'registry.example.com/hermes@sha256:abc' "$WORK/args"
}

@test "the skill is passed as an argument, never spliced into the container's script" {
    install_skill 'x"; touch /tmp/pwned; echo "'
    [ "$status" -eq 0 ]
    # The last argument is the skill, verbatim, after the script's $0.
    [ "$(tail -n 1 "$WORK/args")" = 'x"; touch /tmp/pwned; echo "' ]
    [ "$(tail -n 2 "$WORK/args" | head -n 1)" = sh ]
    run grep -c 'touch /tmp/pwned' "$WORK/args"
    [ "$output" = 1 ]
}

@test "refuses to run outside the project root" {
    rmdir "$WORK/project/config/skills"
    install_skill official/creative/ascii-art
    [ "$status" -ne 0 ]
    [ ! -e "$WORK/args" ]
}
